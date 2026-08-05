import SwiftUI
import MetalKit
import ColmeiaKit

/// Fundo GPU do canvas. Ele é deliberadamente só decorativo: o documento, os
/// gestos e os nós continuam no Canvas SwiftUI, portanto uma GPU indisponível
/// nunca impede alguém de trabalhar no workspace.
struct CanvasMetalBackdrop: NSViewRepresentable {
    let viewport: Viewport
    let isInteracting: Bool

    func makeCoordinator() -> LiquidGlassRenderer { LiquidGlassRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 30
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.025, green: 0.040, blue: 0.070, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.viewport = viewport
        view.isPaused = isInteracting
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.viewport = viewport
        // O fundo é decorativo. Durante pan/zoom ele não pode disputar a main
        // thread/GPU com a cena interativa; a grade e os nós continuam responsivos.
        view.isPaused = isInteracting
    }
}

/// Pequeno renderer Metal criado em código para o pacote SwiftPM não depender
/// de um bundle de `.metal`. O shader desenha reflexos lentos que acompanham o
/// pan do canvas, como uma lâmina de vidro atrás da grade.
final class LiquidGlassRenderer: NSObject, MTKViewDelegate {
    var viewport = Viewport()

    private let start = CACurrentMediaTime()
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let device = view.device,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }
        if queue == nil { queue = device.makeCommandQueue() }
        if pipeline == nil { pipeline = makePipeline(device: device, pixelFormat: view.colorPixelFormat) }
        guard let queue, let pipeline, let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var time = Float(CACurrentMediaTime() - start)
        // O deslocamento é baixo de propósito: o pan dá parallax, não uma textura
        // chamativa que dispute atenção com terminais e notas.
        var drift = SIMD2<Float>(Float(viewport.x * 0.00018), Float(viewport.y * 0.00018))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&time, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&drift, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private func makePipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Out { float4 position [[position]]; float2 uv; };
        vertex Out liquidVertex(uint id [[vertex_id]]) {
            float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            Out out; out.position = float4(p[id], 0.0, 1.0); out.uv = p[id] * 0.5 + 0.5; return out;
        }
        fragment float4 liquidFragment(Out in [[stage_in]], constant float& time [[buffer(0)]], constant float2& drift [[buffer(1)]]) {
            float2 uv = in.uv + drift;
            float wave = sin((uv.x * 4.2 + uv.y * 2.1) + time * 0.18) * 0.5 + 0.5;
            float ripple = sin((uv.x - uv.y) * 7.0 - time * 0.11) * 0.5 + 0.5;
            float glass = wave * 0.55 + ripple * 0.45;
            float3 base = float3(0.025, 0.040, 0.070);
            float3 cool = float3(0.12, 0.34, 0.72);
            float3 warm = float3(0.55, 0.33, 0.16);
            float3 color = mix(base, cool, glass * 0.18);
            color = mix(color, warm, (1.0 - glass) * 0.025);
            return float4(color, 1.0);
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let vertex = library.makeFunction(name: "liquidVertex"),
              let fragment = library.makeFunction(name: "liquidFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}
