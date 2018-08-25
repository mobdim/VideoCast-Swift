//
//  VCPreviewView.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import UIKit
import Metal
import GLKit

open class VCPreviewView: UIView {
    private var vertexBuffer: MTLBuffer?
    private var renderPipelineState: MTLRenderPipelineState?
    private var colorSamplerState: MTLSamplerState?

    private var currentBuffer = 1
    private var paused = Atomic(false)

    private var current = [CVPixelBuffer?](repeating: nil, count: 2)
    private var texture = [CVMetalTexture?](repeating: nil, count: 2)
    private var cache: CVMetalTextureCache?

    private let device = DeviceManager.device
    private var commandQueue: MTLCommandQueue!
    private weak var metalLayer: CAMetalLayer!
    private var _currentDrawable: CAMetalDrawable?
    private var _renderPassDescriptor: MTLRenderPassDescriptor?

    private var layerSizeDidUpdate = false

    final public override class var layerClass: AnyClass {
        return CAMetalLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        configure()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        if let cache = cache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    private func setupRenderPassDescriptorForTexture(_ texture: MTLTexture) {
        // create lazily
        if _renderPassDescriptor == nil {
            _renderPassDescriptor = MTLRenderPassDescriptor()
        }

        guard let renderPassDescriptor = _renderPassDescriptor else { return }
        // create a color attachment every frame since we have to recreate the texture every frame
        renderPassDescriptor.colorAttachments[0].texture = texture

        // make sure to clear every frame for best performance
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1.0)

        // store only attachments that will be presented to the screen
        renderPassDescriptor.colorAttachments[0].storeAction = .store
    }

    private var renderPassDescriptor: MTLRenderPassDescriptor? {
        if let drawable = currentDrawable {
            setupRenderPassDescriptorForTexture(drawable.texture)
        } else {
            // this can happen when the app is backgrounded, in this case just return nil and let the renderer handle it
            _renderPassDescriptor = nil
        }

        return _renderPassDescriptor
    }

    private var currentDrawable: CAMetalDrawable? {
        if _currentDrawable == nil {
            _currentDrawable = metalLayer.nextDrawable()
        }
        return _currentDrawable
    }

    open override var contentScaleFactor: CGFloat {
        get {
            return super.contentScaleFactor
        }
        set {
            super.contentScaleFactor = newValue

            layerSizeDidUpdate = true
        }
    }

    open override func layoutSubviews() {
        super.layoutSubviews()

        backgroundColor = .black
        layerSizeDidUpdate = true
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    open func drawFrame(_ pixelBuffer: CVPixelBuffer) {
        guard !paused.value else { return }

        autoreleasepool {
            var updateTexture = false

            if pixelBuffer != current[currentBuffer] {
                // not found, swap buffers.
                currentBuffer = (currentBuffer + 1) % 2
            }

            if pixelBuffer != current[currentBuffer] {
                // Still not found, update the texture for this buffer.
                current[currentBuffer] = pixelBuffer
                updateTexture = true
            }
            let _currentBuffer = self.currentBuffer

            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return }

                guard let renderPassDescriptor = strongSelf.renderPassDescriptor,
                    let vertexBuffer = strongSelf.vertexBuffer,
                    let renderPipelineState = strongSelf.renderPipelineState,
                    let colorSamplerState = strongSelf.colorSamplerState else { return }

                guard let buffer = strongSelf.current[_currentBuffer], let cache = strongSelf.cache else {
                    fatalError("unexpected return")
                }

                if strongSelf.layerSizeDidUpdate {
                    // set the metal layer to the drawable size in case orientation or size changes
                    var drawableSize = strongSelf.bounds.size
                    drawableSize.width *= strongSelf.contentScaleFactor
                    drawableSize.height *= strongSelf.contentScaleFactor

                    strongSelf.metalLayer.drawableSize = drawableSize

                    strongSelf.layerSizeDidUpdate = false
                }

                if updateTexture {
                    // create a new texture
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                              cache,
                                                              buffer,
                                                              nil,
                                                              MTLPixelFormat.bgra8Unorm,
                                                              CVPixelBufferGetWidth(buffer),
                                                              CVPixelBufferGetHeight(buffer),
                                                              0,
                                                              &strongSelf.texture[_currentBuffer]
                    )

                    if let texture = strongSelf.texture[_currentBuffer] {
                        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    } else {
                        fatalError("could not create texture")
                    }
                }

                defer {
                    CVMetalTextureCacheFlush(cache, 0)
                }

                guard let texture = strongSelf.texture[_currentBuffer] else {
                    fatalError("texture doesn't exist in currentBuffer")
                }

                // draw
                guard let metalTexture = CVMetalTextureGetTexture(texture) else { return }

                let width = Float(CVPixelBufferGetWidth(buffer))
                let height = Float(CVPixelBufferGetHeight(buffer))

                var wfac = Float(strongSelf.bounds.size.width) / width
                var hfac = Float(strongSelf.bounds.size.height) / height

                let aspectFit = false

                let mult = (aspectFit ? (wfac < hfac) : (wfac > hfac)) ? wfac : hfac

                wfac = width * mult / Float(strongSelf.bounds.width)
                hfac = height * mult / Float(strongSelf.bounds.height)

                let matrix = GLKMatrix4ScaleWithVector3(GLKMatrix4Identity, GLKVector3Make(1 * wfac, -1 * hfac, 1))

                var uniforms = Uniforms(modelViewProjectionMatrix: matrix)

                guard let uniformsBuffer = strongSelf.device.makeBuffer(
                    bytes: &uniforms,
                    length: MemoryLayout<Uniforms>.size,
                    options: []) else { return }

                // create a new command buffer for each renderpass to the current drawable
                guard let commandBuffer = strongSelf.commandQueue.makeCommandBuffer() else { return }

                // create a render command encoder so we can render into something
                guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(
                    descriptor: renderPassDescriptor) else { return }

                // setup for GPU debugger
                renderEncoder.pushDebugGroup("preview")

                // set the pipeline state object which contains its precompiled shaders
                renderEncoder.setRenderPipelineState(renderPipelineState)

                // set the static vertex buffers
                renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

                // set the model view project matrix data
                renderEncoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)

                // fragment texture for environment
                renderEncoder.setFragmentTexture(metalTexture, index: 0)

                renderEncoder.setFragmentSamplerState(colorSamplerState, index: 0)

                // tell the render context we want to draw our primitives
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: s_vertexData.count)

                renderEncoder.popDebugGroup()

                renderEncoder.endEncoding()

                if !strongSelf.paused.value {
                    if let currentDrawable = strongSelf.currentDrawable {
                        // schedule a present once the framebuffer is complete
                        commandBuffer.present(currentDrawable)
                        strongSelf._currentDrawable = nil
                    }
                }

                // finalize rendering here. this will push the command buffer to the GPU
                commandBuffer.commit()
            }
        }

    }
}

private extension VCPreviewView {
    func configure() {
        guard let metalLayer = layer as? CAMetalLayer else {
            fatalError("layer is not CAMetalLayer")
        }
        self.metalLayer = metalLayer

        contentScaleFactor = UIScreen.main.scale

        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        DispatchQueue.main.async { [weak self] in
            self?.setupMetal()
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidEnterBackground),
                                               name: .UIApplicationDidEnterBackground, object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationWillEnterForeground),
                                               name: .UIApplicationWillEnterForeground, object: nil)
    }

    @objc func applicationDidEnterBackground() {
        paused.value = true
    }

    @objc func applicationWillEnterForeground() {
        paused.value = false
    }

    func setupMetal() {
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm

        metalLayer.framebufferOnly = true

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)

        commandQueue = device.makeCommandQueue()

        let defaultLibrary: MTLLibrary!
        let bundle = Bundle(for: type(of: self))
        do {
            try defaultLibrary = device.makeDefaultLibrary(bundle: bundle)
        } catch {
            fatalError(">> ERROR: Couldnt create a default shader library")
        }

        // read the vertex and fragment shader functions from the library
        let vertexProgram = defaultLibrary.makeFunction(name: "basic_vertex")
        let fragmentprogram = defaultLibrary.makeFunction(name: "preview_fragment")

        //  create a pipeline state descriptor
        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        renderPipelineDescriptor.label = "PreviewPiplineState"

        // set pixel formats that match the framebuffer we are drawing into
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // set the vertex and fragment programs
        renderPipelineDescriptor.vertexFunction = vertexProgram
        renderPipelineDescriptor.fragmentFunction = fragmentprogram

        do {
            // generate the pipeline state
            try renderPipelineState = device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)
        } catch {
            fatalError("failed to generate the pipeline state \(error)")
        }

        // setup the vertex, texCoord buffers
        vertexBuffer = device.makeBuffer(bytes: s_vertexData,
                                         length: MemoryLayout<Vertex>.size * s_vertexData.count,
                                         options: [])
        vertexBuffer?.label = "PreviewVertexBuffer"

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        colorSamplerState = device.makeSamplerState(descriptor: samplerDescriptor)
    }
}
