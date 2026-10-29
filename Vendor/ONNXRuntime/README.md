# ONNX Runtime C boundary

Unmodified MIT-licensed C API headers from Microsoft ONNX Runtime v1.24.2.
`provenance.json` records upstream URLs and byte hashes. `PIIRuntime.cpp` is
OSwind's bounded, exception-safe wrapper. No runtime binary or model weights
are bundled. The Swift owner verifies explicit local assets before native code
loads. CPU uses four intra-op threads; Core ML explicitly requests MLProgram
with CPUAndGPU and allows remaining operators on CPU. This is not proof that
every operator executes on a GPU.

Calls on a session must be serialized, including destruction. Output is copied
only after its complete shape and every value have been checked. Native calls
are synchronous; cancellation joins the call before destroying its resources.
