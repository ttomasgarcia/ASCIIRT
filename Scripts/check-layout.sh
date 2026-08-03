#!/bin/bash
# Verifica que RenderParams mida lo mismo en Swift y en Metal.
#
# Es el bug más silencioso del proyecto: si los dos lados calculan tamaños
# distintos, todos los campos posteriores al punto de desfasaje se leen
# corridos, y el síntoma es "este parámetro no hace nada" o "hace lo que hace
# otro". No hay error de compilación en ninguno de los dos lados.
#
# Correlo después de tocar RenderParams.h.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/include"
cp "$ROOT/Sources/ShaderTypes/include/RenderParams.h" "$WORK/include/"
printf 'module ShaderTypes { header "RenderParams.h" export * }\n' > "$WORK/include/module.modulemap"

cat > "$WORK/main.swift" <<'EOF'
import Metal
import Foundation
import ShaderTypes

let header = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let source = """
#include <metal_stdlib>
using namespace metal;
\(header)
kernel void probe(device uint *out [[buffer(0)]]) {
    out[0] = (uint)sizeof(RenderParams);
    out[1] = (uint)alignof(RenderParams);
}
"""
let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(source: source, options: nil)
let pso = try device.makeComputePipelineState(function: library.makeFunction(name: "probe")!)
let buffer = device.makeBuffer(length: 8, options: .storageModeShared)!
let queue = device.makeCommandQueue()!
let commandBuffer = queue.makeCommandBuffer()!
let encoder = commandBuffer.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pso)
encoder.setBuffer(buffer, offset: 0, index: 0)
let one = MTLSize(width: 1, height: 1, depth: 1)
encoder.dispatchThreads(one, threadsPerThreadgroup: one)
encoder.endEncoding()
commandBuffer.commit()
commandBuffer.waitUntilCompleted()

let values = buffer.contents().bindMemory(to: UInt32.self, capacity: 2)
let swiftStride = MemoryLayout<RenderParams>.stride
print("Swift: stride \(swiftStride)")
print("Metal: size \(values[0]), align \(values[1])")
if swiftStride == Int(values[0]) {
    print("OK — los dos lados ven el mismo layout")
} else {
    print("DESFASAJE — los parámetros se leen corridos")
    exit(1)
}
EOF

swiftc -O -Xcc -fmodule-map-file="$WORK/include/module.modulemap" -I "$WORK/include" \
    "$WORK/main.swift" -o "$WORK/check" 2>/dev/null
"$WORK/check" "$ROOT/Sources/ShaderTypes/include/RenderParams.h"
