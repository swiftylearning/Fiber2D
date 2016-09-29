#import "CCTexture_Private.h"
#import "CCRenderer_Private.h"
#import "CCShader_Private.h"

#import "CCMetalSupport_Private.h"


// TODO Need to make CCTexture.m MRC to merge this back in?
@implementation CCTexture(NoARC)

+(instancetype)allocWithZone:(struct _NSZone *)zone
{
    return NSAllocateObject([CCTexture class], 0, zone);
}

@end


@implementation CCRenderer(NoARC)

// Positive offset of the vertex allocation to prevent overlapping a boundary.
static inline NSUInteger
PageOffset(NSUInteger firstVertex, NSUInteger vertexCount)
{
	NSCAssert(vertexCount < UINT16_MAX + 1, @"Too many vertexes for a single draw count.");
	
	// Space remaining on the current vertex page.
	NSUInteger remain = (firstVertex | UINT16_MAX) - firstVertex + 1;
	
	if(remain >= vertexCount){
		// Allocation will not overlap a page boundary. 
		return 0;
	} else {
		return remain;
	}
}

-(CCRenderBuffer)enqueueTriangles:(NSUInteger)triangleCount andVertexes:(NSUInteger)vertexCount withState:(CCRenderState *)renderState globalSortOrder:(NSInteger)globalSortOrder;
{
	// Need to record the first vertex or element index before pushing more vertexes.
	NSUInteger firstVertex = _buffers->_vertexBuffer->_count;
	NSUInteger firstIndex = _buffers->_indexBuffer->_count;
	
	// Value is 0 unless there a page boundary overlap would occur.
	NSUInteger vertexPageOffset = PageOffset(firstVertex, vertexCount);
	
	// Split vertexes into pages of 2^16 vertexes since GLES2 requires indexing with shorts.
	NSUInteger vertexPage = (firstVertex + vertexPageOffset) >> 16;
	NSUInteger vertexPageIndex = (firstVertex + vertexPageOffset) & 0xFFFF;
	
	// Ensure that the buffers have enough storage space.
	NSUInteger indexCount = 3*triangleCount;
	CCVertex *vertexes = CCGraphicsBufferPushElements(_buffers->_vertexBuffer, vertexCount + vertexPageOffset);
	uint16_t *elements = CCGraphicsBufferPushElements(_buffers->_indexBuffer, indexCount);
	
	CCRenderCommandDraw *previous = _lastDrawCommand;
	if(previous && previous->_renderState == renderState && previous->_globalSortOrder == globalSortOrder && previous->_vertexPage == vertexPage){
		// Batch with the previous command.
		[previous batch:indexCount];
	} else {
		// Start a new command.
		CCRenderCommandDraw *command = [[CCRenderCommandDrawMetal alloc] initWithMode:CCRenderCommandDrawTriangles renderState:renderState firstIndex:firstIndex vertexPage:vertexPage count:indexCount globalSortOrder:globalSortOrder];
		[_queue addObject:command];
		[command release];
		
		_lastDrawCommand = command;
	}
	
	return (CCRenderBuffer){vertexes, elements, vertexPageIndex};
}

-(CCRenderBuffer)enqueueLines:(NSUInteger)lineCount andVertexes:(NSUInteger)vertexCount withState:(CCRenderState *)renderState globalSortOrder:(NSInteger)globalSortOrder;
{
	// Need to record the first vertex or element index before pushing more vertexes.
	NSUInteger firstVertex = _buffers->_vertexBuffer->_count;
	NSUInteger firstIndex = _buffers->_indexBuffer->_count;
	
	// Value is 0 unless a page boundary overlap would occur.
	NSUInteger vertexPageOffset = PageOffset(firstVertex, vertexCount);
	
	// Split vertexes into pages of 2^16 vertexes since GLES2 requires indexing with shorts.
	NSUInteger vertexPage = (firstVertex + vertexPageOffset) >> 16;
	NSUInteger vertexPageIndex = (firstVertex + vertexPageOffset) & 0xFFFF;
	
	// Ensure that the buffers have enough storage space.
	NSUInteger indexCount = 2*lineCount;
	CCVertex *vertexes = CCGraphicsBufferPushElements(_buffers->_vertexBuffer, vertexCount + vertexPageOffset);
	uint16_t *elements = CCGraphicsBufferPushElements(_buffers->_indexBuffer, indexCount);
	
	CCRenderCommandDraw *command = [[CCRenderCommandDrawMetal alloc] initWithMode:CCRenderCommandDrawLines renderState:renderState firstIndex:firstIndex vertexPage:vertexPage count:indexCount globalSortOrder:globalSortOrder];
	[_queue addObject:command];
	[command release];
	
	// Line drawing commands are currently intended for debugging and cannot be batched.
	_lastDrawCommand = nil;
	
	return(CCRenderBuffer){vertexes, elements, vertexPageIndex};
}

-(void)setRenderState:(CCRenderState *)renderState
{
	if(renderState != _renderState){
		[renderState transitionRenderer:self FromState:_renderState];
		_renderState = renderState;
	}
}

@end


#if __CC_METAL_SUPPORTED_AND_ENABLED

@implementation CCRenderStateMetal {
	id<MTLRenderPipelineState> _renderPipelineState;
}

// Using GL enums for CCBlendMode types should never have happened. Oops.
/*static NSUInteger
GLBLEND_TO_METAL(NSNumber *glenum)
{
	switch(glenum.unsignedIntValue){
		case GL_ZERO: return MTLBlendFactorZero;
		case GL_ONE: return MTLBlendFactorOne;
		case GL_SRC_COLOR: return MTLBlendFactorSourceColor;
		case GL_ONE_MINUS_SRC_COLOR: return MTLBlendFactorOneMinusSourceColor;
		case GL_SRC_ALPHA: return MTLBlendFactorSourceAlpha;
		case GL_ONE_MINUS_SRC_ALPHA: return MTLBlendFactorOneMinusSourceAlpha;
		case GL_DST_COLOR: return MTLBlendFactorDestinationColor;
		case GL_ONE_MINUS_DST_COLOR: return MTLBlendFactorOneMinusDestinationColor;
		case GL_DST_ALPHA: return MTLBlendFactorDestinationAlpha;
		case GL_ONE_MINUS_DST_ALPHA: return MTLBlendFactorOneMinusDestinationAlpha;
		case GL_FUNC_ADD: return MTLBlendOperationAdd;
		case GL_FUNC_SUBTRACT: return MTLBlendOperationSubtract;
		case GL_FUNC_REVERSE_SUBTRACT: return MTLBlendOperationReverseSubtract;
		case GL_MIN_EXT: return MTLBlendOperationMin;
		case GL_MAX_EXT: return MTLBlendOperationMax;
		default:
			NSCAssert(NO, @"Bad enumeration detected in a CCBlendMode. 0x%X", glenum.unsignedIntValue);
			return 0;
	}
    return 0;
}*/

static void
CCRenderStateMetalPrepare(CCRenderStateMetal *self)
{
	if(self->_renderPipelineState == nil){
		// TODO Should get this from the renderer somehow?
		CCMetalContext *context = [CCMetalContext currentContext];
		
		MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
		pipelineStateDescriptor.sampleCount = 1;
		
		pipelineStateDescriptor.vertexFunction = self->_shader->_vertexFunction;
		pipelineStateDescriptor.fragmentFunction = self->_shader->_fragmentFunction;
		
		NSDictionary *blendOptions = self->_blendMode.options;
		MTLRenderPipelineColorAttachmentDescriptor *colorDescriptor = [MTLRenderPipelineColorAttachmentDescriptor new];
		colorDescriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
		colorDescriptor.blendingEnabled = blendOptions != CCBLEND_DISABLED_OPTIONS;
		colorDescriptor.sourceRGBBlendFactor = ((NSNumber*)blendOptions[CCBlendFuncSrcColor]).unsignedIntValue;
		colorDescriptor.sourceAlphaBlendFactor = ((NSNumber*)blendOptions[CCBlendFuncSrcAlpha]).unsignedIntValue;
		colorDescriptor.destinationRGBBlendFactor = ((NSNumber*)blendOptions[CCBlendFuncDstColor]).unsignedIntValue;
		colorDescriptor.destinationAlphaBlendFactor = ((NSNumber*)blendOptions[CCBlendFuncDstAlpha]).unsignedIntValue;
		colorDescriptor.rgbBlendOperation = ((NSNumber*)blendOptions[CCBlendEquationColor]).unsignedIntValue;
		colorDescriptor.alphaBlendOperation = ((NSNumber*)blendOptions[CCBlendEquationAlpha]).unsignedIntValue;
		pipelineStateDescriptor.colorAttachments[0] = colorDescriptor;
		
		NSError *err = nil;
		self->_renderPipelineState = [[context.device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&err] retain];
		
		if(err) CCLOG(@"Error creating metal render pipeline state. %@", err);
		NSCAssert(self->_renderPipelineState, @"Could not create render pipeline state.");
	}
}

static void
CCRenderStateMetalTransition(CCRenderStateMetal *self, CCRenderer *renderer, CCRenderStateMetal *previous)
{
	CCGraphicsBufferBindingsMetal *buffers = (CCGraphicsBufferBindingsMetal *)renderer->_buffers;
	CCMetalContext *context = buffers->_context;
	id<MTLRenderCommandEncoder> renderEncoder = context->_currentRenderCommandEncoder;
	
	// Bind pipeline state.
	[renderEncoder setRenderPipelineState:self->_renderPipelineState];
	
	// Set shader arguments.
	NSDictionary *globalShaderUniforms = renderer->_globalShaderUniforms;
	NSDictionary *setters = self->_shader->_uniformSetters;
	for(NSString *uniformName in setters){
		CCUniformSetter setter = setters[uniformName];
		setter(renderer, self->_shaderUniforms, globalShaderUniforms);
	}
}

-(void)transitionRenderer:(CCRenderer *)renderer FromState:(CCRenderState *)previous
{
	CCRenderStateMetalTransition((CCRenderStateMetal *)self, renderer, (CCRenderStateMetal *)previous);
}

@end

@implementation CCRenderCommandDrawMetal

static const MTLPrimitiveType MetalDrawModes[] = {
	MTLPrimitiveTypeTriangle,
	MTLPrimitiveTypeLine,
};

-(instancetype)initWithMode:(CCRenderCommandDrawMode)mode renderState:(CCRenderState *)renderState firstIndex:(NSUInteger)firstIndex vertexPage:(NSUInteger)vertexPage count:(size_t)count globalSortOrder:(NSInteger)globalSortOrder;
{
	if((self = [super initWithMode:mode renderState:renderState firstIndex:firstIndex vertexPage:vertexPage count:count globalSortOrder:globalSortOrder])){
		// The renderer may have copied the render state, use the ivar.
		CCRenderStateMetalPrepare((CCRenderStateMetal *)_renderState);
	}
	
	return self;
}

-(void)invokeOnRenderer:(CCRenderer *)renderer
{
	CCGraphicsBufferBindingsMetal *buffers = (CCGraphicsBufferBindingsMetal *)renderer->_buffers;
	CCMetalContext *context = buffers->_context;
	id<MTLRenderCommandEncoder> renderEncoder = context->_currentRenderCommandEncoder;
	id<MTLBuffer> indexBuffer = ((CCGraphicsBufferMetal *)buffers->_indexBuffer)->_buffer;
	
	CCMTL_DEBUG_PUSH_GROUP_MARKER(renderEncoder, @"CCRendererCommandDraw: Invoke");
	CCRendererBindBuffers(renderer, YES, _vertexPage);
	CCRenderStateMetalTransition((CCRenderStateMetal *)_renderState, renderer, (CCRenderStateMetal *)renderer->_renderState);
	renderer->_renderState = _renderState;
	
	[renderEncoder drawIndexedPrimitives:MetalDrawModes[_mode] indexCount:_count indexType:MTLIndexTypeUInt16 indexBuffer:indexBuffer indexBufferOffset:2*_firstIndex];
	CCMTL_DEBUG_POP_GROUP_MARKER(renderEncoder);
}

@end

#endif
