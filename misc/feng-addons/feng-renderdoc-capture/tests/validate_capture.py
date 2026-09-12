"""Check actual D3D12 capture commands, labels and scene draws using RenderDoc's exporter."""

from pathlib import Path
import json
import re
import subprocess
import xml.etree.ElementTree as ET


def validate_capture(capture, renderdoccmd, output_dir, custom_name="RenderDoc Tint 中文", explicit=True):
    output_dir = Path(output_dir)
    xml_path = output_dir / "capture.zip.xml"
    subprocess.run([str(renderdoccmd), "convert", "-f", str(capture),
                    "-o", str(xml_path), "-c", "zip.xml"],
                   check=True, capture_output=True, timeout=90)
    stacks = {}
    scene_orders = []
    active_orders = {}
    flattened_orders = {}
    draws = []
    labels = []
    present = False
    configured_label = re.compile(r"^(\d+) (.+)$")
    # The renderer no longer needs an outer "FRP Scene" marker. Keep the
    # capture checks useful for both old captures and the flattened hierarchy,
    # where these labels are the evidence that a draw belongs to the FRP frame.
    scene_operation_labels = {
        "GBuffer",
        "Lighting Preparation",
        "Deferred Lighting",
        "Opaque Forward Fallback",
        "Motion Vectors",
        "Opaque Resolve",
        "Debug Geometry",
        "Sky",
        "Sky Resolve",
        "Subsurface + Specular Merge",
        "Screen/Depth Copy",
        "Transparent",
        "Final Resolve",
        "SSIL/SSR History Copy",
        "Temporal AA / Upscale",
        "Post Process / Tonemap",
        "VT Pass",
        "Render Depth Pre-Pass",
        "Render GBuffer",
        "Render FRP Lighting Pass",
        "Render Opaque Fallback Pass",
        "Render Motion Pass",
        "Draw Sky",
        "Render 3D Transparent Pass",
    }

    def is_scene_label(label):
        return (label == "FRP Scene" or label in scene_operation_labels or
                configured_label.match(label) is not None)

    for _, element in ET.iterparse(xml_path, events=("end",)):
        if element.tag != "chunk":
            continue
        name = element.get("name", "")
        command_list = element.find("ResourceId[@name='pCommandList']")
        if "Present" in name:
            present = True
        if command_list is None:
            element.clear()
            continue
        key = command_list.text
        stack = stacks.setdefault(key, [])
        if name.endswith("::BeginEvent"):
            label = element.findtext("string[@name='MarkerText']", "")
            if label == "Render Setup":
                # The same D3D12 command list may carry more than one scene
                # submission (for example, a viewport and a reflection
                # probe). Do not merge their authored pass indices.
                flattened_orders.pop(key, None)
            if label == "FRP Scene":
                active_orders[key] = []
                scene_orders.append(active_orders[key])
            match = configured_label.match(label)
            if match:
                if "FRP Scene" in stack and key in active_orders:
                    order = active_orders[key]
                else:
                    # A command list can contain a flattened FRP frame with
                    # no wrapper marker. Track its configured labels as one
                    # order, just as the legacy wrapper path did.
                    order = flattened_orders.setdefault(key, [])
                    if order not in scene_orders:
                        scene_orders.append(order)
                order.append((int(match[1]), match[2]))
            stack.append(label)
            labels.append(label)
        elif name.endswith("::EndEvent"):
            assert stack, "Unmatched D3D12 EndEvent in capture"
            ended = stack.pop()
            if ended == "FRP Scene":
                active_orders.pop(key, None)
        elif "::Draw" in name or "::Dispatch" in name:
            if any(is_scene_label(label) for label in stack):
                draws.append({"chunk": int(element.get("chunkIndex")),
                              "operation": name, "path": list(stack),
                              "indices": int(element.findtext("uint[@name='IndexCountPerInstance']", "0"))})
        element.clear()
    assert all(not stack for stack in stacks.values()), "GPU debug labels are not balanced"
    assert present, "Capture contains no presentation"
    assert any("GBuffer" in label for draw in draws if draw["indices"] > 6
               for label in draw["path"]), "Scene mesh draw is missing from GBuffer"
    assert any("Deferred Lighting" in label for draw in draws if "::Draw" in draw["operation"]
               for label in draw["path"]), "Deferred lighting draw is missing"
    if explicit:
        orders = [order for order in scene_orders if order]
        assert orders, "No configured FengRenderer labels were recorded"
        for order in orders:
            positions = [position for position, _ in order]
            assert positions == sorted(positions), f"GPU work crossed a configured pass boundary: {order}"
        assert any(label.endswith("VT Idle Marker") for label in labels), (
            "Idle VT pass lost its configured RenderDoc label"
        )
        assert any(order and order[0] == (0, "VT Idle Marker") for order in orders), (
            "Idle VT pass is not the configured first pass"
        )
        assert not any(
            any(label.endswith("VT Idle Marker") for label in draw["path"])
            for draw in draws
        ), "Idle VT marker unexpectedly submitted draw/dispatch work"
        assert "04 Sky" in labels, "Moved Sky pass does not match its configured position"
        assert any(label.endswith(custom_name) for label in labels), "Custom Unicode pass name is missing"
        assert any(any(label.endswith(custom_name) for label in draw["path"])
                   for draw in draws), "Named custom pass contains no draw/dispatch"
    result = {"capture": str(capture), "scene_orders": scene_orders, "scene_draws": draws}
    (output_dir / "capture-events.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print("PASS captured Scene geometry, deferred lighting, balanced GPU labels"
          + (", configured order and Unicode pass name" if explicit else ""), flush=True)
    return result
