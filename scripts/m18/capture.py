# Captures one frame of the relocated sandbox and inspects its sprite draw, for M18 (RUNBOOK §6).
#
#   qrenderdoc --python capture.py      (with M18_SANDBOX, M18_OUT and M18_ENV_* set; see capture.sh)
#
# It launches the sample through RenderDoc, captures a frame through target control, replays it
# here, and writes what `vulkan.md`'s Step 9 inspected on Windows: the frame's actions, and for
# the largest draw its shaders, bindings, push constants, first vertices before and after the
# vertex stage, viewport, and the target it wrote, saved as a PNG. Then it exits, because
# qrenderdoc would otherwise open its window and wait.

import os
import sys
import time
import json
import traceback

import renderdoc as rd

out = os.environ["M18_OUT"]
report = {}


def say(key, value):
    report[key] = value
    with open(os.path.join(out, "capture.json"), "w") as f:
        json.dump(report, f, indent=2, default=str)


def capture():
    exe = os.environ["M18_SANDBOX"]
    env = []
    for name, value in os.environ.items():
        if name.startswith("M18_ENV_"):
            env.append(rd.EnvironmentModification(rd.EnvMod.Set, rd.EnvSep.NoSep, name[len("M18_ENV_"):], value))
    opts = rd.CaptureOptions()
    result = rd.ExecuteAndInject(exe, os.path.dirname(exe), "", env, os.path.join(out, "sandbox"), opts, False)
    say("inject", str(result.result))
    if result.ident == 0:
        raise RuntimeError("injection failed: " + str(result.result))
    target = rd.CreateTargetControl("", result.ident, "m18", True)
    if target is None:
        raise RuntimeError("no target control")
    time.sleep(6)  # past start-up, into steady frames
    target.TriggerCapture(1)
    path = None
    deadline = time.time() + 60
    while time.time() < deadline and path is None:
        msg = target.ReceiveMessage(None)
        if msg.type == rd.TargetControlMessageType.NewCapture:
            path = msg.newCapture.path
            say("captured", {"frame": msg.newCapture.frameNumber, "path": path, "bytes": os.path.getsize(path) if os.path.exists(path) else None})
    target.Shutdown()
    if path is None:
        raise RuntimeError("no capture arrived")
    return path


def flatten(actions, into):
    for a in actions:
        into.append(a)
        flatten(a.children, into)
    return into


def inspect(path):
    cap = rd.OpenCaptureFile()
    status = cap.OpenFile(path, "", None)
    if status != rd.ResultCode.Succeeded:
        raise RuntimeError("open: " + str(status))
    say("local_replay", str(cap.LocalReplaySupport()))
    status, controller = cap.OpenCapture(rd.ReplayOptions(), None)
    if status != rd.ResultCode.Succeeded:
        raise RuntimeError("replay: " + str(status))
    sf = controller.GetStructuredFile()
    actions = flatten(controller.GetRootActions(), [])
    say("actions", [{"event": a.eventId, "name": a.GetName(sf), "indices": a.numIndices, "flags": str(a.flags)} for a in actions])

    draws = [a for a in actions if a.flags & rd.ActionFlags.Drawcall]
    draw = max(draws, key=lambda a: a.numIndices)
    controller.SetFrameEvent(draw.eventId, True)
    pipe = controller.GetPipelineState()
    detail = {"event": draw.eventId, "indices": draw.numIndices, "instances": draw.numInstances}

    for stage in (rd.ShaderStage.Vertex, rd.ShaderStage.Fragment):
        refl = pipe.GetShaderReflection(stage)
        entry = {"entry": refl.entryPoint if refl else None, "encoding": str(refl.encoding) if refl else None}
        if refl:
            entry["resources"] = [{"name": r.name, "set": r.fixedBindSetOrSpace, "binding": r.fixedBindNumber, "type": str(r.textureType)} for r in refl.readOnlyResources]
            entry["samplers"] = [{"name": s.name, "set": s.fixedBindSetOrSpace, "binding": s.fixedBindNumber} for s in refl.samplers]
            blocks = []
            for i, block in enumerate(refl.constantBlocks):
                values = controller.GetCBufferVariableContents(pipe.GetGraphicsPipelineObject(), refl.resourceId, stage, pipe.GetShaderEntryPoint(stage), i, rd.ResourceId.Null(), 0, 0)
                blocks.append({"name": block.name, "bytes": block.byteSize, "push": block.bufferBacked is False,
                               "values": [{"name": v.name, "rows": v.rows, "columns": v.columns, "f32": list(v.value.f32v[: v.rows * v.columns])} for v in values]})
            entry["constant_blocks"] = blocks
        detail[str(stage)] = entry

    textures = {t.resourceId: t for t in controller.GetTextures()}
    bound = []
    for used in pipe.GetReadOnlyResources(rd.ShaderStage.Fragment):
        rid = used.descriptor.resource
        t = textures.get(rid)
        if t is not None:
            bound.append({"format": str(t.format.Name()), "width": t.width, "height": t.height})
            save = rd.TextureSave()
            save.resourceId = rid
            save.destType = rd.FileType.PNG
            controller.SaveTexture(save, os.path.join(out, "bound-texture.png"))
    detail["fragment_textures"] = bound

    ib = pipe.GetIBuffer()
    detail["index_stride"] = ib.byteStride
    first = controller.GetBufferData(ib.resourceId, ib.byteOffset + draw.indexOffset * ib.byteStride, 6 * ib.byteStride)
    detail["first_indices"] = [int.from_bytes(first[i:i + ib.byteStride], "little") for i in range(0, len(first), ib.byteStride)]
    attrs = pipe.GetVertexInputs()
    detail["vertex_inputs"] = [{"name": a.name, "format": str(a.format.Name()), "offset": a.byteOffset} for a in attrs]
    vbs = pipe.GetVBuffers()
    if vbs:
        detail["vertex_stride"] = vbs[0].byteStride
        raw = controller.GetBufferData(vbs[0].resourceId, vbs[0].byteOffset, vbs[0].byteStride)
        import struct
        detail["first_vertex_floats"] = list(struct.unpack_from("<4f", raw, 0))
    post = controller.GetPostVSData(0, 0, rd.MeshDataStage.VSOut)
    if post.vertexResourceId != rd.ResourceId.Null():
        raw = controller.GetBufferData(post.vertexResourceId, post.vertexByteOffset, post.vertexByteStride)
        import struct
        detail["first_vertex_out_position"] = list(struct.unpack_from("<4f", raw, 0))
    vp = pipe.GetViewport(0)
    detail["viewport"] = {"x": vp.x, "y": vp.y, "width": vp.width, "height": vp.height}

    targets = pipe.GetOutputTargets()
    if targets:
        rid = targets[0].resource
        t = textures.get(rid)
        detail["target"] = {"format": str(t.format.Name()), "width": t.width, "height": t.height} if t else str(rid)
        save = rd.TextureSave()
        save.resourceId = rid
        save.destType = rd.FileType.PNG
        controller.SaveTexture(save, os.path.join(out, "target-after-draw.png"))
    say("draw", detail)
    controller.Shutdown()
    cap.Shutdown()


try:
    inspect(capture())
    say("done", True)
except Exception:
    say("error", traceback.format_exc())
os._exit(0)
