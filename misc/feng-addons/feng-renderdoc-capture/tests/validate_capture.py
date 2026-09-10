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
    draws = []
    labels = []
    present = False
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
            if label == "FRP Scene":
                active_orders[key] = []
                scene_orders.append(active_orders[key])
            if stack and stack[-1] == "FRP Scene":
                match = re.match(r"^(\d+) (.+)$", label)
                if match:
                    active_orders[key].append((int(match[1]), match[2]))
            stack.append(label)
            labels.append(label)
        elif name.endswith("::EndEvent"):
            assert stack, "Unmatched D3D12 EndEvent in capture"
            stack.pop()
        elif "::Draw" in name or "::Dispatch" in name:
            if "FRP Scene" in stack:
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
        assert "03 Sky" in labels, "Moved Sky pass does not match its configured position"
        assert any(label.endswith(custom_name) for label in labels), "Custom Unicode pass name is missing"
        assert any(any(label.endswith(custom_name) for label in draw["path"])
                   for draw in draws), "Named custom pass contains no draw/dispatch"
    result = {"capture": str(capture), "scene_orders": scene_orders, "scene_draws": draws}
    (output_dir / "capture-events.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print("PASS captured Scene geometry, deferred lighting, balanced GPU labels"
          + (", configured order and Unicode pass name" if explicit else ""), flush=True)
    return result
