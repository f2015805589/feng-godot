// Independent GDExtension adapter. No RenderingServer internals or FRP interfaces.
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <libntc/ntc.h>
#include <ConvectionKernels.h>
#include <windows.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace godot;

namespace {
std::mutex gpu_mutex; // Bound transient CUDA memory and never run two training jobs together.
int module_anchor;

struct Library {
    HMODULE module = nullptr;
    decltype(&ntc::CreateContext) create = nullptr;
    decltype(&ntc::DestroyContext) destroy = nullptr;
    decltype(&ntc::GetLastErrorMessage) error = nullptr;
    decltype(&ntc::GetInterfaceVersion) interface_version = nullptr;
    decltype(&ntc::GetLibraryVersion) version = nullptr;
    decltype(&ntc::PickLatentShape) pick_shape = nullptr;
    String failure;

    Library() {
        HMODULE own_module = nullptr;
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                reinterpret_cast<LPCWSTR>(&module_anchor), &own_module);
        wchar_t path[32768] = {};
        if (!GetModuleFileNameW(own_module, path, 32768)) {
            failure = "Cannot locate the Feng NTC extension";
            return;
        }
        std::wstring dll_path(path);
        dll_path = dll_path.substr(0, dll_path.find_last_of(L"\\/") + 1) + L"ntc.dll";
        module = LoadLibraryExW(dll_path.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (!module) {
            failure = "LibNTC runtime is missing or a dependency could not load (Windows error " + String::num_int64(GetLastError()) + "). Run tools/setup_sdk.py.";
            return;
        }
#define RESOLVE(member, name) member = reinterpret_cast<decltype(member)>(GetProcAddress(module, name))
        RESOLVE(create, "CreateContext");
        RESOLVE(destroy, "DestroyContext");
        RESOLVE(error, "GetLastErrorMessage");
        RESOLVE(interface_version, "GetInterfaceVersion");
        RESOLVE(version, "GetLibraryVersion");
        RESOLVE(pick_shape, "PickLatentShape");
#undef RESOLVE
        if (!create || !destroy || !error || !interface_version || !version || !pick_shape) {
            failure = "The installed DLL is not the supported LibNTC runtime";
        } else if (interface_version() != ntc::InterfaceVersion) {
            failure = "LibNTC interface version mismatch. Reinstall the pinned SDK and rebuild the extension.";
        }
    }
    // Keep the CUDA runtime loaded until process exit. Each job releases its own context.
};

Library &library() {
    static Library instance;
    return instance;
}

Dictionary fail(const String &message) {
    Dictionary result;
    result["ok"] = false;
    result["error"] = message;
    return result;
}

String sdk_error(const String &operation, ntc::Status status) {
    return operation + String(": ") + String::utf8(library().error()) + " (NTC " + String::num_int64(int(status)) + ")";
}

struct Session {
    ntc::IContext *context = nullptr;
    ntc::ITextureSet *texture = nullptr;
    ~Session() {
        if (texture) context->DestroyTextureSet(texture);
        if (context) library().destroy(context);
    }
    String initialize(int device) {
        if (!library().failure.is_empty()) return library().failure;
        ntc::ContextParameters parameters;
        parameters.cudaDevice = device;
        parameters.enableCooperativeVector = false;
        const ntc::Status status = library().create(&context, parameters);
        if (status != ntc::Status::Ok) return sdk_error("CUDA initialization (NVIDIA Turing or newer required)", status);
        return String();
    }
};

int mip_count(int width, int height) {
    int count = 1;
    while (width > 1 || height > 1) {
        width = std::max(1, width / 2);
        height = std::max(1, height / 2);
        ++count;
    }
    return count;
}

void make_srgb_mips(Ref<Image> &image) {
    const int width = image->get_width(), height = image->get_height();
    image->convert(Image::FORMAT_RGBAF);
    PackedByteArray pixels = image->get_data();
    auto *values = reinterpret_cast<float *>(pixels.ptrw());
    for (int64_t i = 0; i < pixels.size() / 4; i += 4) {
        for (int c = 0; c < 3; ++c) {
            const float v = values[i + c];
            values[i + c] = v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f);
        }
    }
    image->set_data(width, height, false, Image::FORMAT_RGBAF, pixels);
    image->generate_mipmaps();
    pixels = image->get_data();
    values = reinterpret_cast<float *>(pixels.ptrw());
    for (int64_t i = 0; i < pixels.size() / 4; i += 4) {
        for (int c = 0; c < 3; ++c) {
            const float v = std::max(0.f, values[i + c]);
            values[i + c] = v <= 0.0031308f ? v * 12.92f : 1.055f * std::pow(v, 1.f / 2.4f) - 0.055f;
        }
    }
    image->set_data(width, height, true, Image::FORMAT_RGBAF, pixels);
    image->convert(Image::FORMAT_RGBA8);
}

Ref<Image> encode_bc7(const Ref<Image> &image, bool uniform, const std::atomic<bool> &cancelled) {
    cvtt::Options options;
    options.flags |= cvtt::Flags::BC7_RespectPunchThrough;
    if (uniform) options.flags |= cvtt::Flags::Uniform;
    cvtt::BC7EncodingPlan plan;
    cvtt::Kernels::ConfigureBC7EncodingPlanFromQuality(plan, 3);
    const PackedByteArray input = image->get_data();
    PackedByteArray output;
    const int mips = image->get_mipmap_count() + 1;
    int64_t size = 0;
    for (int mip = 0; mip < mips; ++mip) {
        size += int64_t((std::max(1, image->get_width() >> mip) + 3) / 4) * ((std::max(1, image->get_height() >> mip) + 3) / 4) * 16;
    }
    output.resize(size);
    struct Row { const uint8_t *src; uint8_t *dst; int width, height, y; };
    std::vector<Row> rows;
    uint8_t *destination = output.ptrw();
    for (int mip = 0; mip < mips; ++mip) {
        const int width = std::max(1, image->get_width() >> mip), height = std::max(1, image->get_height() >> mip);
        const auto *source = input.ptr() + image->get_mipmap_offset(mip);
        for (int y = 0; y < height; y += 4) {
            rows.push_back({ source, destination, width, height, y });
            destination += ((width + 3) / 4) * 16;
        }
    }
    std::atomic<size_t> next{ 0 };
    auto work = [&]() {
        cvtt::PixelBlockU8 blocks[cvtt::NumParallelBlocks];
        uint8_t encoded[16 * cvtt::NumParallelBlocks];
        while (!cancelled) {
            const size_t index = next.fetch_add(1);
            if (index >= rows.size()) break;
            const Row &row = rows[index];
            for (int x = 0; x < row.width; x += 4 * cvtt::NumParallelBlocks) {
                for (unsigned int block = 0; block < cvtt::NumParallelBlocks; ++block) {
                    for (int by = 0; by < 4; ++by) {
                        for (int bx = 0; bx < 4; ++bx) {
                            const int px = std::min(row.width - 1, x + int(block) * 4 + bx);
                            const int py = std::min(row.height - 1, row.y + by);
                            memcpy(blocks[block].m_pixels[by * 4 + bx], row.src + (int64_t(py) * row.width + px) * 4, 4);
                        }
                    }
                }
                cvtt::Kernels::EncodeBC7(encoded, blocks, options, plan);
                const int count = std::min(int(cvtt::NumParallelBlocks), (row.width - x + 3) / 4);
                memcpy(row.dst + (x / 4) * 16, encoded, count * 16);
            }
        }
    };
    const unsigned int workers = std::max(1u, std::min(4u, std::thread::hardware_concurrency()));
    std::vector<std::thread> threads;
    for (unsigned int i = 1; i < workers; ++i) threads.emplace_back(work);
    work();
    for (auto &thread : threads) thread.join();
    if (cancelled) return Ref<Image>();
    return Image::create_from_data(image->get_width(), image->get_height(), true, Image::FORMAT_BPTC_RGBA, output);
}

Ref<Image> prepare_material_image(const Ref<Image> &input, const String &name) {
    const int width = input->get_width(), height = input->get_height();
    Ref<Image> image = Image::create_from_data(width, height, false, Image::FORMAT_RGBA8,
            input->get_data().slice(0, int64_t(width) * height * 4));
    if (name == "albedo") make_srgb_mips(image);
    else image->generate_mipmaps(name == "normal");
    return image;
}
} // namespace

class FengNTCCodec : public RefCounted {
    GDCLASS(FengNTCCodec, RefCounted);
    std::atomic<bool> cancelled{ false };
    std::atomic<int> progress{ 0 };
    std::atomic<int> phase{ 0 };
    std::atomic<int> batch{ 0 }, batches{ 0 };

    Dictionary read_images(Session &session, bool block_compress) {
        auto *set = session.texture;
        const auto &desc = set->GetDesc();
        if (desc.width < 4 || desc.height < 4 || desc.width > 8192 || desc.height > 8192 ||
                desc.mips != mip_count(desc.width, desc.height) || set->GetTextureCount() > 16) {
            return fail("Unsupported NTC dimensions or incomplete mip chain (4..8192 pixels and full mips required)");
        }
        const bool terrain = String::utf8(set->GetTexture(0)->GetName()) == "albedo_height";
        const int pixel_bytes = terrain ? 8 : 4;
        Dictionary images;
        for (int index = 0; index < set->GetTextureCount(); ++index) {
            if (cancelled) return fail("Cancelled");
            auto *metadata = set->GetTexture(index);
            const String name = String::utf8(metadata->GetName());
            if ((terrain ? (name != "albedo_height" && name != "normal_roughness" && name != "params") :
                    (name != "albedo" && name != "normal" && name != "orm")) || images.has(name) ||
                    metadata->GetNumChannels() != (terrain || name == "albedo" ? 4 : 3)) {
                return fail("Expected albedo RGBA, normal RGB and orm RGB metadata from Feng NTC");
            }
            // An Image has a contiguous mip chain, including the 1x1 tail.
            PackedByteArray pixels;
            int64_t size = 0;
            for (int mip = 0; mip < desc.mips; ++mip) {
                size += int64_t(std::max(1, desc.width >> mip)) * std::max(1, desc.height >> mip) * pixel_bytes;
            }
            pixels.resize(size);
            // Three-channel maps have no alpha in NTC; BC7 and Image still require opaque RGBA.
            if (metadata->GetNumChannels() == 3) {
                auto *bytes = pixels.ptrw();
                for (int64_t i = 3; i < size; i += 4) bytes[i] = 255;
            }
            int64_t offset = 0;
            const ntc::ColorSpace spaces[4] = { metadata->GetRgbColorSpace(), metadata->GetRgbColorSpace(),
                metadata->GetRgbColorSpace(), metadata->GetAlphaColorSpace() };
            for (int mip = 0; mip < desc.mips; ++mip) {
                ntc::ReadChannelsParameters read;
                read.mipLevel = mip;
                read.firstChannel = metadata->GetFirstChannel();
                read.numChannels = metadata->GetNumChannels();
                read.width = std::max(1, desc.width >> mip);
                read.height = std::max(1, desc.height >> mip);
                read.pOutData = pixels.ptrw() + offset;
                read.pixelStride = pixel_bytes;
                read.rowPitch = size_t(read.width) * pixel_bytes;
                read.channelFormat = terrain ? ntc::ChannelFormat::FLOAT16 : ntc::ChannelFormat::UNORM8;
                read.dstColorSpaces = spaces;
                read.useDithering = false;
                const auto status = set->ReadChannels(read);
                if (status != ntc::Status::Ok) return fail(sdk_error("Read decoded texels", status));
                offset += int64_t(read.width) * read.height * pixel_bytes;
            }
            Ref<Image> image = Image::create_from_data(desc.width, desc.height, true, terrain ? Image::FORMAT_RGBAH : Image::FORMAT_RGBA8, pixels);
            if (block_compress && !terrain) {
                phase = 4;
                // Bundle the encoder: exported engines need not enable the optional CVTT module.
                image = encode_bc7(image, name != "albedo", cancelled);
                if (image.is_null()) return fail("Cancelled");
            }
            images[name] = image;
        }
        if (!images.has(terrain ? "albedo_height" : "albedo")) return fail("NTC has no primary image");
        Dictionary result;
        result["ok"] = true;
        result["images"] = images;
        return result;
    }

protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("get_status"), &FengNTCCodec::get_status);
        ClassDB::bind_method(D_METHOD("set_batch", "index", "count"), &FengNTCCodec::set_batch);
        ClassDB::bind_method(D_METHOD("cancel"), &FengNTCCodec::cancel);
        ClassDB::bind_method(D_METHOD("compress_material", "images", "bits_per_pixel", "training_steps", "cuda_device"), &FengNTCCodec::compress_material, DEFVAL(0));
        ClassDB::bind_method(D_METHOD("decode_material", "payload", "cuda_device", "block_compress"), &FengNTCCodec::decode_material, DEFVAL(0), DEFVAL(true));
        ClassDB::bind_method(D_METHOD("get_sdk_status"), &FengNTCCodec::get_sdk_status);
        ClassDB::bind_method(D_METHOD("encode_bc7_material", "images"), &FengNTCCodec::encode_bc7_material);
        ClassDB::bind_method(D_METHOD("prepare_portable", "payload"), &FengNTCCodec::prepare_portable);
        ClassDB::bind_method(D_METHOD("compress_terrain_pages", "images", "bits_per_pixel", "training_steps", "cuda_device"), &FengNTCCodec::compress_terrain_pages, DEFVAL(0));
    }

public:
    // Editor/import operation only. No graphics device or CUDA context is required.
    // Package the documented GenericInt8 representation for the portable RD decoder.
    Dictionary prepare_portable(const PackedByteArray &data) {
        if (data.is_empty() || data.size() > 512ll * 1024 * 1024) return fail("Invalid NTC payload");
        if (!library().failure.is_empty()) return fail(library().failure);
        Session session;
        ntc::ContextParameters params;
        params.cudaDevice = ntc::DisableCudaDevice;
        params.enableCooperativeVector = false;
        auto status = library().create(&session.context, params);
        if (!session.context || (status != ntc::Status::Ok && status != ntc::Status::CudaUnavailable))
            return fail(sdk_error("Create metadata-only NTC context", status));
        ntc::IStream *stream = nullptr;
        status = session.context->OpenReadOnlyMemory(data.ptr(), size_t(data.size()), &stream);
        if (status != ntc::Status::Ok) return fail(sdk_error("Open NTC", status));
        ntc::ITextureSetMetadata *metadata = nullptr;
        status = session.context->CreateTextureSetMetadataFromStream(stream, &metadata);
        session.context->CloseMemory(stream);
        if (status != ntc::Status::Ok) return fail(sdk_error("Parse NTC metadata", status));
        struct MetadataGuard {
            ntc::IContext *context;
            ntc::ITextureSetMetadata *metadata;
            ~MetadataGuard() { context->DestroyTextureSetMetadata(metadata); }
        } guard{ session.context, metadata };
        const auto desc = metadata->GetDesc();
        const auto latent_desc = metadata->GetLatentTextureDesc();
        if (desc.width < 4 || desc.height < 4 || desc.width > 8192 || desc.height > 8192 ||
                desc.mips != mip_count(desc.width, desc.height) || desc.channels > 16 ||
                latent_desc.arraySize < 1 || latent_desc.arraySize > 4 || latent_desc.mipLevels > 16)
            return fail("Unsupported NTC layout");
        const void *weights = nullptr;
        size_t weight_size = 0, converted_size = 0;
        status = metadata->GetInferenceWeights(ntc::InferenceWeightType::GenericInt8, &weights, &weight_size, &converted_size);
        if (status != ntc::Status::Ok || !weights || converted_size) return fail("NTC payload must contain GenericInt8 weights");
        ntc::InferenceData inference{};
        status = session.context->MakeInferenceData(metadata, ntc::InferenceWeightType::GenericInt8, 0, &inference);
        if (status != ntc::Status::Ok) return fail(sdk_error("Prepare portable inference", status));
        PackedByteArray weight_data, constants, latents;
        weight_data.resize(weight_size);
        memcpy(weight_data.ptrw(), weights, weight_size);
        constants.resize(sizeof(inference.constants));
        memcpy(constants.ptrw(), &inference.constants, sizeof(inference.constants));
        PackedInt32Array layout;
        for (int mip = 0; mip < latent_desc.mipLevels; ++mip) {
            for (int layer = 0; layer < latent_desc.arraySize; ++layer) {
                ntc::LatentTextureFootprint footprint;
                status = metadata->GetLatentTextureFootprint(mip, layer, footprint);
                if (status != ntc::Status::Ok) return fail(sdk_error("Read latent footprint", status));
                const auto &buffer = footprint.buffer;
                if (buffer.rangeInStream.offset > uint64_t(data.size()) ||
                        buffer.rangeInStream.size > uint64_t(data.size()) - buffer.rangeInStream.offset ||
                        buffer.uncompressedSize > 128 * 1024 * 1024 ||
                        buffer.uncompressedSize < footprint.rowPitch * footprint.height)
                    return fail("Invalid latent buffer bounds");
                const int64_t offset = latents.size();
                latents.resize(offset + ((buffer.uncompressedSize + 3) & ~uint64_t(3)));
                status = session.context->DecompressBuffer(buffer.compressionType,
                        data.ptr() + buffer.rangeInStream.offset, buffer.rangeInStream.size,
                        latents.ptrw() + offset, buffer.uncompressedSize, buffer.uncompressedCrc32);
                if (status != ntc::Status::Ok) return fail(sdk_error("Unpack latent stream", status));
                layout.push_back(int32_t(offset));
                layout.push_back(footprint.width);
                layout.push_back(footprint.height);
                layout.push_back(int32_t(footprint.rowPitch));
            }
        }
        const bool terrain = String::utf8(metadata->GetTexture(0)->GetName()) == "albedo_height";
        Dictionary maps;
        for (int i = 0; i < metadata->GetTextureCount(); ++i) {
            const auto *texture = metadata->GetTexture(i);
            String name = String::utf8(texture->GetName());
            if ((terrain ? (name != "albedo_height" && name != "normal_roughness" && name != "params") :
                    (name != "albedo" && name != "normal" && name != "orm")) || maps.has(name) ||
                    texture->GetNumChannels() != (terrain || name == "albedo" ? 4 : 3)) return fail("Unsupported NTC channels");
            Dictionary map;
            map["first"] = texture->GetFirstChannel();
            map["count"] = texture->GetNumChannels();
            map["rgb_space"] = int(texture->GetRgbColorSpace());
            map["alpha_space"] = int(texture->GetAlphaColorSpace());
            maps[name] = map;
        }
        if (terrain ? maps.size() != 3 : !maps.has("albedo")) return fail("Incomplete NTC channels");
        Dictionary package;
        package["version"] = 1;
        if (terrain) package["kind"] = "terrain_vt";
        package["width"] = desc.width;
        package["height"] = desc.height;
        package["mips"] = desc.mips;
        package["layers"] = latent_desc.arraySize;
        package["latent_mips"] = latent_desc.mipLevels;
        package["constants"] = constants;
        package["weights"] = weight_data;
        package["latents"] = latents;
        package["layout"] = layout;
        package["maps"] = maps;
        Dictionary result;
        result["ok"] = true;
        result["package"] = package;
        return result;
    }

    Dictionary get_sdk_status() const {
        if (!library().failure.is_empty()) return fail(library().failure);
        Dictionary result;
        result["ok"] = true;
        const auto version = library().version();
        result["version"] = String::num_int64(version.major) + "." + String::num_int64(version.minor) + "." + String::num_int64(version.point);
        result["backend"] = "CUDA on-load; BC7 CPU transcode";
        return result;
    }
    void cancel() { cancelled = true; }
    void set_batch(int index, int count) { batch = index; batches = count; }
    Dictionary get_status() const {
        Dictionary result;
        result["phase"] = phase.load();
        result["steps"] = progress.load();
        result["batch"] = batch.load();
        result["batches"] = batches.load();
        return result;
    }

    // CPU-only BC7 baseline/export. Uses exactly the encoder and mip policy of NTC transcoding.
    Dictionary encode_bc7_material(const Dictionary &inputs) {
        if (!inputs.has("albedo") || inputs.size() > 3) return fail("Expected albedo with optional normal and orm images");
        Dictionary reference, compressed;
        int width = 0, height = 0;
        for (const char *name : { "albedo", "normal", "orm" }) {
            if (!inputs.has(name)) continue;
            Ref<Image> input = inputs[name];
            if (input.is_null() || input->is_empty() || input->get_format() != Image::FORMAT_RGBA8) return fail("Input must be RGBA8");
            if (!width) { width = input->get_width(); height = input->get_height(); }
            if (width < 4 || height < 4 || width > 8192 || height > 8192 || (width & (width - 1)) || (height & (height - 1)) ||
                    input->get_width() != width || input->get_height() != height) return fail("Invalid material dimensions");
            if (cancelled) return fail("Cancelled");
            Ref<Image> image = prepare_material_image(input, name);
            reference[name] = image;
            Ref<Image> output = encode_bc7(image, String(name) != "albedo", cancelled);
            if (output.is_null()) return fail("Cancelled");
            compressed[name] = output;
        }
        Dictionary result;
        result["ok"] = true;
        result["images"] = compressed;
        result["reference_images"] = reference;
        return result;
    }

    Dictionary compress_material(const Dictionary &inputs, double bpp, int steps, int device) {
        return compress_set(inputs, bpp, steps, device, false);
    }
    Dictionary compress_terrain_pages(const Dictionary &inputs, double bpp, int steps, int device) {
        return compress_set(inputs, bpp, steps, device, true);
    }
    Dictionary compress_set(const Dictionary &inputs, double bpp, int steps, int device, bool terrain) {
        progress = 0;
        std::unique_lock<std::mutex> lock(gpu_mutex, std::defer_lock);
        while (!lock.try_lock()) {
            if (cancelled) return fail("Cancelled");
            Sleep(10);
        }
        if (cancelled) return fail("Cancelled");
        if (!std::isfinite(bpp) || bpp < 1 || bpp > 20 || steps < 128 || steps > 1000000 || device < 0) {
            return fail("Invalid compression parameters");
        }
        if (terrain ? (!inputs.has("albedo_height") || !inputs.has("normal_roughness") || !inputs.has("params") || inputs.size()!=3) : (!inputs.has("albedo") || inputs.size()>3)) return fail("Invalid NTC input maps");
        Ref<Image> first = inputs[terrain ? "albedo_height" : "albedo"];
        if (first.is_null() || first->is_empty()) return fail("Empty albedo image");
        ntc::TextureSetDesc desc;
        desc.width = first->get_width();
        desc.height = first->get_height();
        desc.channels = terrain ? 12 : 4 + (inputs.has("normal") ? 3 : 0) + (inputs.has("orm") ? 3 : 0);
        desc.mips = mip_count(desc.width, desc.height);
        if (desc.width < 4 || desc.height < 4 || desc.width > 8192 || desc.height > 8192 ||
                (desc.width & (desc.width - 1)) || (desc.height & (desc.height - 1))) {
            return fail("Use power-of-two material textures between 4 and 8192 pixels");
        }
        phase = 1;
        Session session;
        String error = session.initialize(device);
        if (!error.is_empty()) return fail(error);
        ntc::TextureSetFeatures features;
        features.stagingBytesPerPixel = terrain ? 16 : 4;
        auto status = session.context->CreateTextureSet(desc, features, &session.texture);
        if (status != ntc::Status::Ok) return fail(sdk_error("Create texture set", status));
        ntc::LatentShape shape;
        float actual_bpp = 0;
        status = library().pick_shape(float(bpp), actual_bpp, shape);
        if (status != ntc::Status::Ok) return fail(sdk_error("Choose bitrate", status));
        status = session.texture->SetLatentShape(shape);
        if (status != ntc::Status::Ok) return fail(sdk_error("Set bitrate", status));
        int channel = 0;
        const char *pbr_names[] = {"albedo", "normal", "orm"};
        const char *vt_names[] = {"albedo_height", "normal_roughness", "params"};
        for (int map_index=0; map_index<3; ++map_index) {
            const char *name = terrain ? vt_names[map_index] : pbr_names[map_index];
            if (!inputs.has(name)) continue;
            Ref<Image> input = inputs[name];
            if (input.is_null() || input->is_empty() || input->is_compressed() || input->get_width() != desc.width || input->get_height() != desc.height) {
                return fail("Material image dimensions/formats do not match");
            }
            // Input preparation supplies RGBA8, with full-precision source maps handled before packing.
            if (!terrain && input->get_format() != Image::FORMAT_RGBA8) return fail("Input must be RGBA8");
            Ref<Image> image;
            if (terrain) {
                // Already evaluated, linear VT channels; retain signed world normals,
                // roughness, height, AO, normal depth and validity. No PBR repacking.
                image = input->duplicate();
                image->convert(Image::FORMAT_RGBAF);
                if (!image->has_mipmaps()) image->generate_mipmaps();
            } else image = prepare_material_image(input, name);
            const bool srgb = !terrain && String(name) == "albedo";
            const int channels = terrain || srgb ? 4 : 3;
            const int pixel_bytes = terrain ? 16 : 4;
            auto *metadata = session.texture->AddTexture();
            metadata->SetName(name);
            metadata->SetChannels(channel, channels);
            metadata->SetChannelFormat(terrain ? ntc::ChannelFormat::FLOAT16 : ntc::ChannelFormat::UNORM8);
            metadata->SetBlockCompressedFormat(ntc::BlockCompressedFormat::BC7);
            metadata->SetRgbColorSpace(srgb ? ntc::ColorSpace::sRGB : ntc::ColorSpace::Linear);
            metadata->SetAlphaColorSpace(ntc::ColorSpace::Linear);
            const ntc::ColorSpace spaces[4] = { metadata->GetRgbColorSpace(), metadata->GetRgbColorSpace(), metadata->GetRgbColorSpace(), ntc::ColorSpace::Linear };
            PackedByteArray pixels = image->get_data();
            for (int mip = 0; mip < desc.mips; ++mip) {
                ntc::WriteChannelsParameters write;
                write.mipLevel = mip;
                write.firstChannel = channel;
                write.numChannels = channels;
                write.width = std::max(1, desc.width >> mip);
                write.height = std::max(1, desc.height >> mip);
                write.pData = pixels.ptr() + image->get_mipmap_offset(mip);
                write.pixelStride = pixel_bytes;
                write.rowPitch = size_t(write.width) * pixel_bytes;
                write.channelFormat = terrain ? ntc::ChannelFormat::FLOAT32 : ntc::ChannelFormat::UNORM8;
                write.srcColorSpaces = spaces;
                write.dstColorSpaces = spaces;
                status = session.texture->WriteChannels(write);
                if (status != ntc::Status::Ok) return fail(sdk_error("Upload material", status));
            }
            channel += channels;
        }
        session.texture->SetMaskChannelIndex(terrain ? -1 : 3, false);
        ntc::CompressionSettings settings;
        settings.trainingSteps = steps;
        settings.stepsPerIteration = std::min(128, steps);
        settings.randomSeed = 42;
        status = session.texture->BeginCompression(settings);
        if (status != ntc::Status::Ok) return fail(sdk_error("Begin compression", status));
        phase = 2;
        ntc::CompressionStats stats;
        do {
            if (cancelled) {
                session.texture->AbortCompression();
                return fail("Cancelled");
            }
            status = session.texture->RunCompressionSteps(&stats);
            progress = stats.currentStep;
        } while (status == ntc::Status::Incomplete);
        if (status != ntc::Status::Ok) return fail(sdk_error("Train material decoder", status));
        status = session.texture->FinalizeCompression();
        if (status != ntc::Status::Ok) return fail(sdk_error("Finalize compression", status));
        // No extra lossless worker pool or BC mode buffer is needed by this CUDA adapter.
        ntc::LosslessCompressionSettings lossless;
        lossless.algorithm = ntc::CompressionType::None;
        lossless.compressionThreads = -1;
        session.texture->ConfigureLosslessCompression(lossless);
        PackedByteArray data;
        size_t size = size_t(session.texture->GetOutputStreamSize());
        data.resize(size);
        status = session.texture->SaveToMemory(data.ptrw(), &size);
        if (status != ntc::Status::Ok) return fail(sdk_error("Save NTC", status));
        data.resize(size);
        phase = 3;
        ntc::DecompressionStats decode_stats{};
        status = session.texture->Decompress(&decode_stats, true);
        if (status != ntc::Status::Ok) return fail(sdk_error("Verify NTC decoding", status));
        // Preview is optional raw output; production no longer does an expensive CPU BC7 transcode.
        Dictionary result = read_images(session, false);
        if (!bool(result.get("ok", false))) return result;
        Dictionary portable = prepare_portable(data);
        if (!bool(portable.get("ok", false))) return portable;
        result["package"] = portable["package"];
        result["payload"] = data;
        result["actual_bpp"] = actual_bpp;
        result["psnr"] = decode_stats.overallLoss > 0 ? -10.0 * std::log10(decode_stats.overallLoss) : 100.0;
        result["gpu_decode_ms"] = decode_stats.gpuTimeMilliseconds;
        phase = 5;
        return result;
    }

    Dictionary decode_material(const PackedByteArray &data, int device, bool block_compress) {
        if (data.is_empty() || data.size() > 512ll * 1024 * 1024 || device < 0) return fail("Invalid NTC payload or device");
        std::unique_lock<std::mutex> lock(gpu_mutex, std::defer_lock);
        while (!lock.try_lock()) {
            if (cancelled) return fail("Cancelled");
            Sleep(10);
        }
        if (cancelled) return fail("Cancelled");
        phase = 1;
        Session session;
        String error = session.initialize(device);
        if (!error.is_empty()) return fail(error);
        // Validate metadata before allocating GPU tensors for externally supplied files.
        ntc::IStream *stream = nullptr;
        auto status = session.context->OpenReadOnlyMemory(data.ptr(), size_t(data.size()), &stream);
        if (status != ntc::Status::Ok) return fail(sdk_error("Open NTC", status));
        ntc::ITextureSetMetadata *metadata = nullptr;
        status = session.context->CreateTextureSetMetadataFromStream(stream, &metadata);
        session.context->CloseMemory(stream);
        if (status != ntc::Status::Ok) return fail(sdk_error("Read NTC metadata", status));
        const auto desc = metadata->GetDesc();
        session.context->DestroyTextureSetMetadata(metadata);
        if (desc.width < 4 || desc.height < 4 || desc.width > 8192 || desc.height > 8192 || desc.channels < 1 || desc.channels > 16 || desc.mips != mip_count(desc.width, desc.height)) {
            return fail("NTC metadata exceeds supported dimensions/channels or has incomplete mips");
        }
        status = session.context->CreateCompressedTextureSetFromMemory(data.ptr(), size_t(data.size()), ntc::TextureSetFeatures(), &session.texture);
        if (status != ntc::Status::Ok) return fail(sdk_error("Load NTC", status));
        phase = 3;
        ntc::DecompressionStats stats{};
        status = session.texture->Decompress(&stats, true);
        if (status != ntc::Status::Ok) return fail(sdk_error("Decode NTC", status));
        Dictionary result = read_images(session, block_compress);
        result["gpu_decode_ms"] = stats.gpuTimeMilliseconds;
        phase = 5;
        return result;
    }
};

extern "C" GDExtensionBool GDE_EXPORT feng_ntc_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
        GDExtensionClassLibraryPtr library_handle, GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library_handle, initialization);
    init.register_initializer([](ModuleInitializationLevel level) {
        if (level == MODULE_INITIALIZATION_LEVEL_SCENE) ClassDB::register_class<FengNTCCodec>();
    });
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
