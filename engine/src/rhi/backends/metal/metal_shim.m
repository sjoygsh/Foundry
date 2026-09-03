/*
 * The Metal bridge (ADR-0012). See `metal_shim.h` for the contract this implements and for
 * why it is written the way it is.
 *
 * Compiled with ARC (`-fobjc-arc`), which is the whole reason this file exists in
 * Objective-C rather than as `objc_msgSend` calls from Zig: object lifetime stays where the
 * language handles it correctly. Ownership crosses the boundary explicitly —
 * `__bridge_retained` when a handle leaves, `__bridge_transfer` when it comes back to be
 * destroyed — so every `create` here is balanced by exactly one `destroy`.
 *
 * Functions that produce autoreleased Metal objects wrap them in an `@autoreleasepool`.
 * Without it the pool backing a game's frame loop would never drain, and command buffers
 * would accumulate for the life of the process.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <string.h>

#include "metal_shim.h"

/* -- the header's constants really are Metal's ---------------------------------------- */

/*
 * Checked here because this is the only file that can see both. A wrong value would not
 * produce an error at any layer above: it would silently sample the wrong texture, blend
 * with the wrong factor, or clear to the wrong format. This makes that a build failure.
 *
 * There are as many assertions as there are constants, deliberately. Spot-checking a few
 * would leave exactly the mistakes this is meant to catch.
 */
_Static_assert(FD_MTL_PIXEL_FORMAT_INVALID == MTLPixelFormatInvalid, "FD_MTL_PIXEL_FORMAT_INVALID");
_Static_assert(FD_MTL_PIXEL_FORMAT_R8_UNORM == MTLPixelFormatR8Unorm, "FD_MTL_PIXEL_FORMAT_R8_UNORM");
_Static_assert(FD_MTL_PIXEL_FORMAT_R16_FLOAT == MTLPixelFormatR16Float, "FD_MTL_PIXEL_FORMAT_R16_FLOAT");
_Static_assert(FD_MTL_PIXEL_FORMAT_RG8_UNORM == MTLPixelFormatRG8Unorm, "FD_MTL_PIXEL_FORMAT_RG8_UNORM");
_Static_assert(FD_MTL_PIXEL_FORMAT_R32_FLOAT == MTLPixelFormatR32Float, "FD_MTL_PIXEL_FORMAT_R32_FLOAT");
_Static_assert(FD_MTL_PIXEL_FORMAT_RGBA8_UNORM == MTLPixelFormatRGBA8Unorm, "FD_MTL_PIXEL_FORMAT_RGBA8_UNORM");
_Static_assert(FD_MTL_PIXEL_FORMAT_RGBA8_UNORM_SRGB == MTLPixelFormatRGBA8Unorm_sRGB, "FD_MTL_PIXEL_FORMAT_RGBA8_UNORM_SRGB");
_Static_assert(FD_MTL_PIXEL_FORMAT_BGRA8_UNORM == MTLPixelFormatBGRA8Unorm, "FD_MTL_PIXEL_FORMAT_BGRA8_UNORM");
_Static_assert(FD_MTL_PIXEL_FORMAT_BGRA8_UNORM_SRGB == MTLPixelFormatBGRA8Unorm_sRGB, "FD_MTL_PIXEL_FORMAT_BGRA8_UNORM_SRGB");
_Static_assert(FD_MTL_PIXEL_FORMAT_RGBA16_FLOAT == MTLPixelFormatRGBA16Float, "FD_MTL_PIXEL_FORMAT_RGBA16_FLOAT");
_Static_assert(FD_MTL_PIXEL_FORMAT_RGBA32_FLOAT == MTLPixelFormatRGBA32Float, "FD_MTL_PIXEL_FORMAT_RGBA32_FLOAT");
_Static_assert(FD_MTL_PIXEL_FORMAT_DEPTH32_FLOAT == MTLPixelFormatDepth32Float, "FD_MTL_PIXEL_FORMAT_DEPTH32_FLOAT");
_Static_assert(FD_MTL_PIXEL_FORMAT_DEPTH32_FLOAT_STENCIL8 == MTLPixelFormatDepth32Float_Stencil8, "FD_MTL_PIXEL_FORMAT_DEPTH32_FLOAT_STENCIL8");
_Static_assert(FD_MTL_VERTEX_FORMAT_UCHAR4 == MTLVertexFormatUChar4, "FD_MTL_VERTEX_FORMAT_UCHAR4");
_Static_assert(FD_MTL_VERTEX_FORMAT_UCHAR4_NORMALIZED == MTLVertexFormatUChar4Normalized, "FD_MTL_VERTEX_FORMAT_UCHAR4_NORMALIZED");
_Static_assert(FD_MTL_VERTEX_FORMAT_USHORT2 == MTLVertexFormatUShort2, "FD_MTL_VERTEX_FORMAT_USHORT2");
_Static_assert(FD_MTL_VERTEX_FORMAT_FLOAT == MTLVertexFormatFloat, "FD_MTL_VERTEX_FORMAT_FLOAT");
_Static_assert(FD_MTL_VERTEX_FORMAT_FLOAT2 == MTLVertexFormatFloat2, "FD_MTL_VERTEX_FORMAT_FLOAT2");
_Static_assert(FD_MTL_VERTEX_FORMAT_FLOAT3 == MTLVertexFormatFloat3, "FD_MTL_VERTEX_FORMAT_FLOAT3");
_Static_assert(FD_MTL_VERTEX_FORMAT_FLOAT4 == MTLVertexFormatFloat4, "FD_MTL_VERTEX_FORMAT_FLOAT4");
_Static_assert(FD_MTL_VERTEX_FORMAT_UINT == MTLVertexFormatUInt, "FD_MTL_VERTEX_FORMAT_UINT");
_Static_assert(FD_MTL_INDEX_TYPE_UINT16 == MTLIndexTypeUInt16, "FD_MTL_INDEX_TYPE_UINT16");
_Static_assert(FD_MTL_INDEX_TYPE_UINT32 == MTLIndexTypeUInt32, "FD_MTL_INDEX_TYPE_UINT32");
_Static_assert(FD_MTL_LOAD_ACTION_DONT_CARE == MTLLoadActionDontCare, "FD_MTL_LOAD_ACTION_DONT_CARE");
_Static_assert(FD_MTL_LOAD_ACTION_LOAD == MTLLoadActionLoad, "FD_MTL_LOAD_ACTION_LOAD");
_Static_assert(FD_MTL_LOAD_ACTION_CLEAR == MTLLoadActionClear, "FD_MTL_LOAD_ACTION_CLEAR");
_Static_assert(FD_MTL_STORE_ACTION_DONT_CARE == MTLStoreActionDontCare, "FD_MTL_STORE_ACTION_DONT_CARE");
_Static_assert(FD_MTL_STORE_ACTION_STORE == MTLStoreActionStore, "FD_MTL_STORE_ACTION_STORE");
_Static_assert(FD_MTL_STORAGE_MODE_SHARED == MTLStorageModeShared, "FD_MTL_STORAGE_MODE_SHARED");
_Static_assert(FD_MTL_STORAGE_MODE_MANAGED == MTLStorageModeManaged, "FD_MTL_STORAGE_MODE_MANAGED");
_Static_assert(FD_MTL_STORAGE_MODE_PRIVATE == MTLStorageModePrivate, "FD_MTL_STORAGE_MODE_PRIVATE");
_Static_assert(FD_MTL_RESOURCE_STORAGE_MODE_SHARED == MTLResourceStorageModeShared, "FD_MTL_RESOURCE_STORAGE_MODE_SHARED");
_Static_assert(FD_MTL_RESOURCE_STORAGE_MODE_MANAGED == MTLResourceStorageModeManaged, "FD_MTL_RESOURCE_STORAGE_MODE_MANAGED");
_Static_assert(FD_MTL_RESOURCE_STORAGE_MODE_PRIVATE == MTLResourceStorageModePrivate, "FD_MTL_RESOURCE_STORAGE_MODE_PRIVATE");
_Static_assert(FD_MTL_TEXTURE_USAGE_SHADER_READ == MTLTextureUsageShaderRead, "FD_MTL_TEXTURE_USAGE_SHADER_READ");
_Static_assert(FD_MTL_TEXTURE_USAGE_SHADER_WRITE == MTLTextureUsageShaderWrite, "FD_MTL_TEXTURE_USAGE_SHADER_WRITE");
_Static_assert(FD_MTL_TEXTURE_USAGE_RENDER_TARGET == MTLTextureUsageRenderTarget, "FD_MTL_TEXTURE_USAGE_RENDER_TARGET");
_Static_assert(FD_MTL_PRIMITIVE_TYPE_POINT == MTLPrimitiveTypePoint, "FD_MTL_PRIMITIVE_TYPE_POINT");
_Static_assert(FD_MTL_PRIMITIVE_TYPE_LINE == MTLPrimitiveTypeLine, "FD_MTL_PRIMITIVE_TYPE_LINE");
_Static_assert(FD_MTL_PRIMITIVE_TYPE_LINE_STRIP == MTLPrimitiveTypeLineStrip, "FD_MTL_PRIMITIVE_TYPE_LINE_STRIP");
_Static_assert(FD_MTL_PRIMITIVE_TYPE_TRIANGLE == MTLPrimitiveTypeTriangle, "FD_MTL_PRIMITIVE_TYPE_TRIANGLE");
_Static_assert(FD_MTL_PRIMITIVE_TYPE_TRIANGLE_STRIP == MTLPrimitiveTypeTriangleStrip, "FD_MTL_PRIMITIVE_TYPE_TRIANGLE_STRIP");
_Static_assert(FD_MTL_CULL_MODE_NONE == MTLCullModeNone, "FD_MTL_CULL_MODE_NONE");
_Static_assert(FD_MTL_CULL_MODE_FRONT == MTLCullModeFront, "FD_MTL_CULL_MODE_FRONT");
_Static_assert(FD_MTL_CULL_MODE_BACK == MTLCullModeBack, "FD_MTL_CULL_MODE_BACK");
_Static_assert(FD_MTL_WINDING_CLOCKWISE == MTLWindingClockwise, "FD_MTL_WINDING_CLOCKWISE");
_Static_assert(FD_MTL_WINDING_COUNTER_CLOCKWISE == MTLWindingCounterClockwise, "FD_MTL_WINDING_COUNTER_CLOCKWISE");
_Static_assert(FD_MTL_COMPARE_NEVER == MTLCompareFunctionNever, "FD_MTL_COMPARE_NEVER");
_Static_assert(FD_MTL_COMPARE_LESS == MTLCompareFunctionLess, "FD_MTL_COMPARE_LESS");
_Static_assert(FD_MTL_COMPARE_EQUAL == MTLCompareFunctionEqual, "FD_MTL_COMPARE_EQUAL");
_Static_assert(FD_MTL_COMPARE_LESS_EQUAL == MTLCompareFunctionLessEqual, "FD_MTL_COMPARE_LESS_EQUAL");
_Static_assert(FD_MTL_COMPARE_GREATER == MTLCompareFunctionGreater, "FD_MTL_COMPARE_GREATER");
_Static_assert(FD_MTL_COMPARE_NOT_EQUAL == MTLCompareFunctionNotEqual, "FD_MTL_COMPARE_NOT_EQUAL");
_Static_assert(FD_MTL_COMPARE_GREATER_EQUAL == MTLCompareFunctionGreaterEqual, "FD_MTL_COMPARE_GREATER_EQUAL");
_Static_assert(FD_MTL_COMPARE_ALWAYS == MTLCompareFunctionAlways, "FD_MTL_COMPARE_ALWAYS");
_Static_assert(FD_MTL_BLEND_FACTOR_ZERO == MTLBlendFactorZero, "FD_MTL_BLEND_FACTOR_ZERO");
_Static_assert(FD_MTL_BLEND_FACTOR_ONE == MTLBlendFactorOne, "FD_MTL_BLEND_FACTOR_ONE");
_Static_assert(FD_MTL_BLEND_FACTOR_SRC_COLOR == MTLBlendFactorSourceColor, "FD_MTL_BLEND_FACTOR_SRC_COLOR");
_Static_assert(FD_MTL_BLEND_FACTOR_ONE_MINUS_SRC_COLOR == MTLBlendFactorOneMinusSourceColor, "FD_MTL_BLEND_FACTOR_ONE_MINUS_SRC_COLOR");
_Static_assert(FD_MTL_BLEND_FACTOR_SRC_ALPHA == MTLBlendFactorSourceAlpha, "FD_MTL_BLEND_FACTOR_SRC_ALPHA");
_Static_assert(FD_MTL_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA == MTLBlendFactorOneMinusSourceAlpha, "FD_MTL_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA");
_Static_assert(FD_MTL_BLEND_FACTOR_DST_COLOR == MTLBlendFactorDestinationColor, "FD_MTL_BLEND_FACTOR_DST_COLOR");
_Static_assert(FD_MTL_BLEND_FACTOR_ONE_MINUS_DST_COLOR == MTLBlendFactorOneMinusDestinationColor, "FD_MTL_BLEND_FACTOR_ONE_MINUS_DST_COLOR");
_Static_assert(FD_MTL_BLEND_FACTOR_DST_ALPHA == MTLBlendFactorDestinationAlpha, "FD_MTL_BLEND_FACTOR_DST_ALPHA");
_Static_assert(FD_MTL_BLEND_FACTOR_ONE_MINUS_DST_ALPHA == MTLBlendFactorOneMinusDestinationAlpha, "FD_MTL_BLEND_FACTOR_ONE_MINUS_DST_ALPHA");
_Static_assert(FD_MTL_BLEND_OP_ADD == MTLBlendOperationAdd, "FD_MTL_BLEND_OP_ADD");
_Static_assert(FD_MTL_BLEND_OP_SUBTRACT == MTLBlendOperationSubtract, "FD_MTL_BLEND_OP_SUBTRACT");
_Static_assert(FD_MTL_BLEND_OP_REVERSE_SUBTRACT == MTLBlendOperationReverseSubtract, "FD_MTL_BLEND_OP_REVERSE_SUBTRACT");
_Static_assert(FD_MTL_BLEND_OP_MIN == MTLBlendOperationMin, "FD_MTL_BLEND_OP_MIN");
_Static_assert(FD_MTL_BLEND_OP_MAX == MTLBlendOperationMax, "FD_MTL_BLEND_OP_MAX");
_Static_assert(FD_MTL_COLOR_WRITE_MASK_NONE == MTLColorWriteMaskNone, "FD_MTL_COLOR_WRITE_MASK_NONE");
_Static_assert(FD_MTL_COLOR_WRITE_MASK_ALPHA == MTLColorWriteMaskAlpha, "FD_MTL_COLOR_WRITE_MASK_ALPHA");
_Static_assert(FD_MTL_COLOR_WRITE_MASK_BLUE == MTLColorWriteMaskBlue, "FD_MTL_COLOR_WRITE_MASK_BLUE");
_Static_assert(FD_MTL_COLOR_WRITE_MASK_GREEN == MTLColorWriteMaskGreen, "FD_MTL_COLOR_WRITE_MASK_GREEN");
_Static_assert(FD_MTL_COLOR_WRITE_MASK_RED == MTLColorWriteMaskRed, "FD_MTL_COLOR_WRITE_MASK_RED");
_Static_assert(FD_MTL_COLOR_WRITE_MASK_ALL == MTLColorWriteMaskAll, "FD_MTL_COLOR_WRITE_MASK_ALL");
_Static_assert(FD_MTL_SAMPLER_FILTER_NEAREST == MTLSamplerMinMagFilterNearest, "FD_MTL_SAMPLER_FILTER_NEAREST");
_Static_assert(FD_MTL_SAMPLER_FILTER_LINEAR == MTLSamplerMinMagFilterLinear, "FD_MTL_SAMPLER_FILTER_LINEAR");
_Static_assert(FD_MTL_SAMPLER_MIP_NOT_MIPMAPPED == MTLSamplerMipFilterNotMipmapped, "FD_MTL_SAMPLER_MIP_NOT_MIPMAPPED");
_Static_assert(FD_MTL_SAMPLER_MIP_NEAREST == MTLSamplerMipFilterNearest, "FD_MTL_SAMPLER_MIP_NEAREST");
_Static_assert(FD_MTL_SAMPLER_MIP_LINEAR == MTLSamplerMipFilterLinear, "FD_MTL_SAMPLER_MIP_LINEAR");
_Static_assert(FD_MTL_SAMPLER_ADDRESS_CLAMP_TO_EDGE == MTLSamplerAddressModeClampToEdge, "FD_MTL_SAMPLER_ADDRESS_CLAMP_TO_EDGE");
_Static_assert(FD_MTL_SAMPLER_ADDRESS_REPEAT == MTLSamplerAddressModeRepeat, "FD_MTL_SAMPLER_ADDRESS_REPEAT");
_Static_assert(FD_MTL_SAMPLER_ADDRESS_MIRROR_REPEAT == MTLSamplerAddressModeMirrorRepeat, "FD_MTL_SAMPLER_ADDRESS_MIRROR_REPEAT");
_Static_assert(FD_MTL_VERTEX_STEP_PER_VERTEX == MTLVertexStepFunctionPerVertex, "FD_MTL_VERTEX_STEP_PER_VERTEX");
_Static_assert(FD_MTL_VERTEX_STEP_PER_INSTANCE == MTLVertexStepFunctionPerInstance, "FD_MTL_VERTEX_STEP_PER_INSTANCE");

/* -- helpers ------------------------------------------------------------------------- */

static void fd_set_label(id object, const char *label) {
    if (label == NULL || label[0] == '\0') return;
    NSString *s = [NSString stringWithUTF8String:label];
    if (s != nil) [object setLabel:s];
}

static void fd_copy_error(NSError *error, char *out, int32_t cap) {
    if (out == NULL || cap <= 0) return;
    out[0] = '\0';
    if (error == nil) return;

    const char *message = [[error localizedDescription] UTF8String];
    if (message == NULL) return;

    size_t room = (size_t)cap - 1;
    size_t len = strlen(message);
    if (len > room) len = room;
    memcpy(out, message, len);
    out[len] = '\0';
}

/* -- device -------------------------------------------------------------------------- */

FdMtlDevice *fd_mtl_device_create(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) return NULL;
        return (__bridge_retained FdMtlDevice *)device;
    }
}

void fd_mtl_device_destroy(FdMtlDevice *dev) {
    if (dev == NULL) return;
    id<MTLDevice> device = (__bridge_transfer id<MTLDevice>)dev;
    (void)device;
}

int32_t fd_mtl_device_name(FdMtlDevice *dev, char *out, int32_t cap) {
    if (dev == NULL || out == NULL || cap <= 0) return -1;
    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)dev;
        const char *name = [[device name] UTF8String];
        if (name == NULL) {
            out[0] = '\0';
            return 0;
        }
        size_t room = (size_t)cap - 1;
        size_t len = strlen(name);
        if (len > room) len = room;
        memcpy(out, name, len);
        out[len] = '\0';
        return (int32_t)len;
    }
}

bool fd_mtl_device_has_unified_memory(FdMtlDevice *dev) {
    if (dev == NULL) return false;
    id<MTLDevice> device = (__bridge id<MTLDevice>)dev;
    return [device hasUnifiedMemory];
}

uint32_t fd_mtl_device_max_texture_dimension(FdMtlDevice *dev) {
    if (dev == NULL) return 0;
    id<MTLDevice> device = (__bridge id<MTLDevice>)dev;
    /* Both modern families guarantee 16384; the fallback is the older Apple-family limit.
     * Reported rather than assumed, because `Capabilities` is allowed to describe something
     * better than the RHI's guaranteed minimum but never something worse. */
    if ([device supportsFamily:MTLGPUFamilyApple3]) return 16384;
    if ([device supportsFamily:MTLGPUFamilyMac2]) return 16384;
    return 8192;
}

/* -- queue --------------------------------------------------------------------------- */

FdMtlQueue *fd_mtl_queue_create(FdMtlDevice *dev, const char *label) {
    if (dev == NULL) return NULL;
    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)dev;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (queue == nil) return NULL;
        fd_set_label(queue, label);
        return (__bridge_retained FdMtlQueue *)queue;
    }
}

void fd_mtl_queue_destroy(FdMtlQueue *queue) {
    if (queue == NULL) return;
    id<MTLCommandQueue> q = (__bridge_transfer id<MTLCommandQueue>)queue;
    (void)q;
}

/* -- layer and drawables -------------------------------------------------------------- */

void fd_mtl_layer_configure(void *layer, FdMtlDevice *dev, uint32_t pixel_format,
                            uint32_t width, uint32_t height, bool vsync) {
    if (layer == NULL || dev == NULL) return;
    @autoreleasepool {
        CAMetalLayer *l = (__bridge CAMetalLayer *)layer;
        l.device = (__bridge id<MTLDevice>)dev;
        l.pixelFormat = (MTLPixelFormat)pixel_format;
        l.framebufferOnly = YES;
        l.drawableSize = CGSizeMake((CGFloat)width, (CGFloat)height);
        l.displaySyncEnabled = vsync ? YES : NO;
    }
}

uint32_t fd_mtl_layer_pixel_format(void *layer) {
    if (layer == NULL) return 0;
    CAMetalLayer *l = (__bridge CAMetalLayer *)layer;
    return (uint32_t)l.pixelFormat;
}

FdMtlDrawable *fd_mtl_layer_next_drawable(void *layer) {
    if (layer == NULL) return NULL;
    @autoreleasepool {
        CAMetalLayer *l = (__bridge CAMetalLayer *)layer;
        id<CAMetalDrawable> drawable = [l nextDrawable];
        if (drawable == nil) return NULL;
        return (__bridge_retained FdMtlDrawable *)drawable;
    }
}

void fd_mtl_drawable_destroy(FdMtlDrawable *drawable) {
    if (drawable == NULL) return;
    id<CAMetalDrawable> d = (__bridge_transfer id<CAMetalDrawable>)drawable;
    (void)d;
}

FdMtlTexture *fd_mtl_drawable_texture(FdMtlDrawable *drawable) {
    if (drawable == NULL) return NULL;
    @autoreleasepool {
        id<CAMetalDrawable> d = (__bridge id<CAMetalDrawable>)drawable;
        id<MTLTexture> texture = [d texture];
        if (texture == nil) return NULL;
        return (__bridge_retained FdMtlTexture *)texture;
    }
}

/* -- buffers ------------------------------------------------------------------------- */

FdMtlBuffer *fd_mtl_buffer_create(FdMtlDevice *dev, uint64_t length,
                                  uint32_t resource_options, const char *label) {
    if (dev == NULL) return NULL;
    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)dev;
        id<MTLBuffer> buffer = [device newBufferWithLength:(NSUInteger)length
                                                   options:(MTLResourceOptions)resource_options];
        if (buffer == nil) return NULL;
        fd_set_label(buffer, label);
        return (__bridge_retained FdMtlBuffer *)buffer;
    }
}

void fd_mtl_buffer_destroy(FdMtlBuffer *buffer) {
    if (buffer == NULL) return;
    id<MTLBuffer> b = (__bridge_transfer id<MTLBuffer>)buffer;
    (void)b;
}

void *fd_mtl_buffer_contents(FdMtlBuffer *buffer) {
    if (buffer == NULL) return NULL;
    id<MTLBuffer> b = (__bridge id<MTLBuffer>)buffer;
    return [b contents];
}

void fd_mtl_buffer_did_modify_range(FdMtlBuffer *buffer, uint64_t offset, uint64_t length) {
    if (buffer == NULL || length == 0) return;
    id<MTLBuffer> b = (__bridge id<MTLBuffer>)buffer;
    if ([b storageMode] != MTLStorageModeManaged) return;
    [b didModifyRange:NSMakeRange((NSUInteger)offset, (NSUInteger)length)];
}

/* -- textures ------------------------------------------------------------------------ */

FdMtlTexture *fd_mtl_texture_create(FdMtlDevice *dev, const FdMtlTextureDesc *desc,
                                    const char *label) {
    if (dev == NULL || desc == NULL) return NULL;
    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)dev;

        MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
        d.textureType = MTLTextureType2D;
        d.pixelFormat = (MTLPixelFormat)desc->pixel_format;
        d.width = desc->width;
        d.height = desc->height;
        d.depth = 1;
        d.mipmapLevelCount = desc->mip_levels == 0 ? 1 : desc->mip_levels;
        d.sampleCount = 1;
        d.arrayLength = 1;
        d.usage = (MTLTextureUsage)desc->usage;
        d.storageMode = (MTLStorageMode)desc->storage_mode;

        id<MTLTexture> texture = [device newTextureWithDescriptor:d];
        if (texture == nil) return NULL;
        fd_set_label(texture, label);
        return (__bridge_retained FdMtlTexture *)texture;
    }
}

void fd_mtl_texture_destroy(FdMtlTexture *texture) {
    if (texture == NULL) return;
    id<MTLTexture> t = (__bridge_transfer id<MTLTexture>)texture;
    (void)t;
}

uint32_t fd_mtl_texture_width(FdMtlTexture *texture) {
    if (texture == NULL) return 0;
    id<MTLTexture> t = (__bridge id<MTLTexture>)texture;
    return (uint32_t)[t width];
}

uint32_t fd_mtl_texture_height(FdMtlTexture *texture) {
    if (texture == NULL) return 0;
    id<MTLTexture> t = (__bridge id<MTLTexture>)texture;
    return (uint32_t)[t height];
}

/* -- samplers ------------------------------------------------------------------------ */

FdMtlSampler *fd_mtl_sampler_create(FdMtlDevice *dev, const FdMtlSamplerDesc *desc,
                                    const char *label) {
    if (dev == NULL || desc == NULL) return NULL;
    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)dev;

        MTLSamplerDescriptor *d = [[MTLSamplerDescriptor alloc] init];
        d.minFilter = (MTLSamplerMinMagFilter)desc->min_filter;
        d.magFilter = (MTLSamplerMinMagFilter)desc->mag_filter;
        d.mipFilter = (MTLSamplerMipFilter)desc->mip_filter;
        d.sAddressMode = (MTLSamplerAddressMode)desc->address_u;
        d.tAddressMode = (MTLSamplerAddressMode)desc->address_v;
        if (label != NULL && label[0] != '\0') {
            d.label = [NSString stringWithUTF8String:label];
        }

        id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:d];
        if (sampler == nil) return NULL;
        return (__bridge_retained FdMtlSampler *)sampler;
    }
}

void fd_mtl_sampler_destroy(FdMtlSampler *sampler) {
    if (sampler == NULL) return;
    id<MTLSamplerState> s = (__bridge_transfer id<MTLSamplerState>)sampler;
    (void)s;
}

/* -- shader libraries ----------------------------------------------------------------- */

FdMtlLibrary *fd_mtl_library_from_data(FdMtlDevice *dev, const void *bytes, size_t len,
                                       char *err, int32_t err_cap) {
    if (err != NULL && err_cap > 0) err[0] = '\0';
    if (dev == NULL || bytes == NULL || len == 0) return NULL;

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)dev;

        dispatch_data_t data = dispatch_data_create(bytes, len,
                                                    dispatch_get_main_queue(),
                                                    DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithData:data error:&error];
        if (library == nil) {
            fd_copy_error(error, err, err_cap);
            return NULL;
        }
        return (__bridge_retained FdMtlLibrary *)library;
    }
}

FdMtlLibrary *fd_mtl_library_from_source(FdMtlDevice *dev, const char *source,
                                         char *err, int32_t err_cap) {
    if (err != NULL && err_cap > 0) err[0] = '\0';
    if (dev == NULL || source == NULL) return NULL;

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)dev;

        NSString *text = [NSString stringWithUTF8String:source];
        if (text == nil) return NULL;

        MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:text
                                                      options:options
                                                        error:&error];
        if (library == nil) {
            fd_copy_error(error, err, err_cap);
            return NULL;
        }
        return (__bridge_retained FdMtlLibrary *)library;
    }
}

void fd_mtl_library_destroy(FdMtlLibrary *library) {
    if (library == NULL) return;
    id<MTLLibrary> l = (__bridge_transfer id<MTLLibrary>)library;
    (void)l;
}

FdMtlFunction *fd_mtl_library_function(FdMtlLibrary *library, const char *name) {
    if (library == NULL || name == NULL) return NULL;
    @autoreleasepool {
        id<MTLLibrary> l = (__bridge id<MTLLibrary>)library;
        NSString *n = [NSString stringWithUTF8String:name];
        if (n == nil) return NULL;
        id<MTLFunction> function = [l newFunctionWithName:n];
        if (function == nil) return NULL;
        return (__bridge_retained FdMtlFunction *)function;
    }
}

void fd_mtl_function_destroy(FdMtlFunction *function) {
    if (function == NULL) return;
    id<MTLFunction> f = (__bridge_transfer id<MTLFunction>)function;
    (void)f;
}

/* -- render pipelines ------------------------------------------------------------------ */

FdMtlRenderPipeline *fd_mtl_render_pipeline_create(FdMtlDevice *dev,
                                                   const FdMtlRenderPipelineDesc *desc,
                                                   char *err, int32_t err_cap) {
    if (err != NULL && err_cap > 0) err[0] = '\0';
    if (dev == NULL || desc == NULL) return NULL;

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)dev;

        MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction = (__bridge id<MTLFunction>)desc->vertex_function;
        d.fragmentFunction = (__bridge id<MTLFunction>)desc->fragment_function;
        if (desc->label != NULL && desc->label[0] != '\0') {
            d.label = [NSString stringWithUTF8String:desc->label];
        }

        if (desc->attribute_count > 0 || desc->vertex_layout_count > 0) {
            MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
            for (uint32_t i = 0; i < desc->attribute_count; i += 1) {
                const FdMtlVertexAttribute *a = &desc->attributes[i];
                vd.attributes[a->location].format = (MTLVertexFormat)a->format;
                vd.attributes[a->location].offset = a->offset;
                vd.attributes[a->location].bufferIndex = a->buffer_index;
            }
            for (uint32_t i = 0; i < desc->vertex_layout_count; i += 1) {
                const FdMtlVertexBufferLayout *l = &desc->vertex_layouts[i];
                vd.layouts[l->buffer_index].stride = l->stride;
                vd.layouts[l->buffer_index].stepFunction =
                    (MTLVertexStepFunction)l->step_function;
                vd.layouts[l->buffer_index].stepRate = 1;
            }
            d.vertexDescriptor = vd;
        }

        for (uint32_t i = 0; i < desc->color_target_count; i += 1) {
            const FdMtlColorTarget *t = &desc->color_targets[i];
            MTLRenderPipelineColorAttachmentDescriptor *ca = d.colorAttachments[i];
            ca.pixelFormat = (MTLPixelFormat)t->pixel_format;
            ca.writeMask = (MTLColorWriteMask)t->write_mask;
            ca.blendingEnabled = t->blending_enabled ? YES : NO;
            ca.sourceRGBBlendFactor = (MTLBlendFactor)t->src_rgb;
            ca.destinationRGBBlendFactor = (MTLBlendFactor)t->dst_rgb;
            ca.rgbBlendOperation = (MTLBlendOperation)t->rgb_op;
            ca.sourceAlphaBlendFactor = (MTLBlendFactor)t->src_alpha;
            ca.destinationAlphaBlendFactor = (MTLBlendFactor)t->dst_alpha;
            ca.alphaBlendOperation = (MTLBlendOperation)t->alpha_op;
        }

        if (desc->depth_pixel_format != MTLPixelFormatInvalid) {
            d.depthAttachmentPixelFormat = (MTLPixelFormat)desc->depth_pixel_format;
        }

        NSError *error = nil;
        id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:d
                                                                                error:&error];
        if (pso == nil) {
            fd_copy_error(error, err, err_cap);
            return NULL;
        }
        return (__bridge_retained FdMtlRenderPipeline *)pso;
    }
}

void fd_mtl_render_pipeline_destroy(FdMtlRenderPipeline *pipeline) {
    if (pipeline == NULL) return;
    id<MTLRenderPipelineState> p = (__bridge_transfer id<MTLRenderPipelineState>)pipeline;
    (void)p;
}

FdMtlDepthState *fd_mtl_depth_state_create(FdMtlDevice *dev,
                                           const FdMtlDepthStateDesc *desc) {
    if (dev == NULL || desc == NULL) return NULL;
    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)dev;

        MTLDepthStencilDescriptor *d = [[MTLDepthStencilDescriptor alloc] init];
        d.depthCompareFunction = (MTLCompareFunction)desc->compare;
        d.depthWriteEnabled = desc->write_enabled ? YES : NO;

        id<MTLDepthStencilState> state = [device newDepthStencilStateWithDescriptor:d];
        if (state == nil) return NULL;
        return (__bridge_retained FdMtlDepthState *)state;
    }
}

void fd_mtl_depth_state_destroy(FdMtlDepthState *state) {
    if (state == NULL) return;
    id<MTLDepthStencilState> s = (__bridge_transfer id<MTLDepthStencilState>)state;
    (void)s;
}

/* -- command buffers -------------------------------------------------------------------- */

FdMtlCommandBuffer *fd_mtl_command_buffer_create(FdMtlQueue *queue, const char *label) {
    if (queue == NULL) return NULL;
    @autoreleasepool {
        id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        if (cb == nil) return NULL;
        fd_set_label(cb, label);
        return (__bridge_retained FdMtlCommandBuffer *)cb;
    }
}

void fd_mtl_command_buffer_destroy(FdMtlCommandBuffer *cb) {
    if (cb == NULL) return;
    id<MTLCommandBuffer> c = (__bridge_transfer id<MTLCommandBuffer>)cb;
    (void)c;
}

void fd_mtl_command_buffer_present(FdMtlCommandBuffer *cb, FdMtlDrawable *drawable) {
    if (cb == NULL || drawable == NULL) return;
    id<MTLCommandBuffer> c = (__bridge id<MTLCommandBuffer>)cb;
    id<CAMetalDrawable> d = (__bridge id<CAMetalDrawable>)drawable;
    [c presentDrawable:d];
}

void fd_mtl_command_buffer_commit(FdMtlCommandBuffer *cb) {
    if (cb == NULL) return;
    id<MTLCommandBuffer> c = (__bridge id<MTLCommandBuffer>)cb;
    [c commit];
}

void fd_mtl_command_buffer_wait_until_completed(FdMtlCommandBuffer *cb) {
    if (cb == NULL) return;
    id<MTLCommandBuffer> c = (__bridge id<MTLCommandBuffer>)cb;
    [c waitUntilCompleted];
}

/* -- render encoders --------------------------------------------------------------------- */

FdMtlRenderEncoder *fd_mtl_render_encoder_begin(FdMtlCommandBuffer *cb,
                                                const FdMtlRenderPassDesc *desc) {
    if (cb == NULL || desc == NULL) return NULL;
    @autoreleasepool {
        id<MTLCommandBuffer> c = (__bridge id<MTLCommandBuffer>)cb;

        MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
        for (uint32_t i = 0; i < desc->color_count; i += 1) {
            const FdMtlColorAttachment *a = &desc->color[i];
            d.colorAttachments[i].texture = (__bridge id<MTLTexture>)a->texture;
            d.colorAttachments[i].loadAction = (MTLLoadAction)a->load_action;
            d.colorAttachments[i].storeAction = (MTLStoreAction)a->store_action;
            d.colorAttachments[i].clearColor =
                MTLClearColorMake(a->clear_r, a->clear_g, a->clear_b, a->clear_a);
        }
        if (desc->depth != NULL) {
            d.depthAttachment.texture = (__bridge id<MTLTexture>)desc->depth->texture;
            d.depthAttachment.loadAction = (MTLLoadAction)desc->depth->load_action;
            d.depthAttachment.storeAction = (MTLStoreAction)desc->depth->store_action;
            d.depthAttachment.clearDepth = desc->depth->clear_depth;
        }

        id<MTLRenderCommandEncoder> enc = [c renderCommandEncoderWithDescriptor:d];
        if (enc == nil) return NULL;
        fd_set_label(enc, desc->label);
        return (__bridge_retained FdMtlRenderEncoder *)enc;
    }
}

void fd_mtl_render_encoder_end(FdMtlRenderEncoder *enc) {
    if (enc == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e endEncoding];
}

void fd_mtl_render_encoder_destroy(FdMtlRenderEncoder *enc) {
    if (enc == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge_transfer id<MTLRenderCommandEncoder>)enc;
    (void)e;
}

void fd_mtl_render_encoder_set_pipeline(FdMtlRenderEncoder *enc, FdMtlRenderPipeline *pso) {
    if (enc == NULL || pso == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e setRenderPipelineState:(__bridge id<MTLRenderPipelineState>)pso];
}

void fd_mtl_render_encoder_set_depth_state(FdMtlRenderEncoder *enc, FdMtlDepthState *state) {
    if (enc == NULL || state == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e setDepthStencilState:(__bridge id<MTLDepthStencilState>)state];
}

void fd_mtl_render_encoder_set_cull_mode(FdMtlRenderEncoder *enc, uint32_t mode) {
    if (enc == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e setCullMode:(MTLCullMode)mode];
}

void fd_mtl_render_encoder_set_front_face(FdMtlRenderEncoder *enc, uint32_t winding) {
    if (enc == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e setFrontFacingWinding:(MTLWinding)winding];
}

void fd_mtl_render_encoder_set_viewport(FdMtlRenderEncoder *enc, double x, double y,
                                        double width, double height,
                                        double znear, double zfar) {
    if (enc == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    MTLViewport vp = {x, y, width, height, znear, zfar};
    [e setViewport:vp];
}

void fd_mtl_render_encoder_set_scissor(FdMtlRenderEncoder *enc, uint32_t x, uint32_t y,
                                       uint32_t width, uint32_t height) {
    if (enc == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    MTLScissorRect r = {x, y, width, height};
    [e setScissorRect:r];
}

void fd_mtl_render_encoder_set_vertex_buffer(FdMtlRenderEncoder *enc, FdMtlBuffer *buffer,
                                             uint64_t offset, uint32_t index) {
    if (enc == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e setVertexBuffer:(__bridge id<MTLBuffer>)buffer
                offset:(NSUInteger)offset
               atIndex:index];
}

void fd_mtl_render_encoder_set_vertex_bytes(FdMtlRenderEncoder *enc, const void *bytes,
                                            size_t len, uint32_t index) {
    if (enc == NULL || bytes == NULL || len == 0) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e setVertexBytes:bytes length:len atIndex:index];
}

void fd_mtl_render_encoder_set_vertex_texture(FdMtlRenderEncoder *enc, FdMtlTexture *texture,
                                              uint32_t index) {
    if (enc == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e setVertexTexture:(__bridge id<MTLTexture>)texture atIndex:index];
}

void fd_mtl_render_encoder_set_vertex_sampler(FdMtlRenderEncoder *enc, FdMtlSampler *sampler,
                                              uint32_t index) {
    if (enc == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e setVertexSamplerState:(__bridge id<MTLSamplerState>)sampler atIndex:index];
}

void fd_mtl_render_encoder_set_fragment_buffer(FdMtlRenderEncoder *enc, FdMtlBuffer *buffer,
                                               uint64_t offset, uint32_t index) {
    if (enc == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e setFragmentBuffer:(__bridge id<MTLBuffer>)buffer
                  offset:(NSUInteger)offset
                 atIndex:index];
}

void fd_mtl_render_encoder_set_fragment_bytes(FdMtlRenderEncoder *enc, const void *bytes,
                                              size_t len, uint32_t index) {
    if (enc == NULL || bytes == NULL || len == 0) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e setFragmentBytes:bytes length:len atIndex:index];
}

void fd_mtl_render_encoder_set_fragment_texture(FdMtlRenderEncoder *enc,
                                                FdMtlTexture *texture, uint32_t index) {
    if (enc == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e setFragmentTexture:(__bridge id<MTLTexture>)texture atIndex:index];
}

void fd_mtl_render_encoder_set_fragment_sampler(FdMtlRenderEncoder *enc,
                                                FdMtlSampler *sampler, uint32_t index) {
    if (enc == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e setFragmentSamplerState:(__bridge id<MTLSamplerState>)sampler atIndex:index];
}

void fd_mtl_render_encoder_draw(FdMtlRenderEncoder *enc, uint32_t primitive,
                                uint32_t vertex_start, uint32_t vertex_count,
                                uint32_t instance_count, uint32_t base_instance) {
    if (enc == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e drawPrimitives:(MTLPrimitiveType)primitive
          vertexStart:vertex_start
          vertexCount:vertex_count
        instanceCount:instance_count
         baseInstance:base_instance];
}

void fd_mtl_render_encoder_draw_indexed(FdMtlRenderEncoder *enc, uint32_t primitive,
                                        uint32_t index_count, uint32_t index_type,
                                        FdMtlBuffer *index_buffer, uint64_t index_offset,
                                        uint32_t instance_count, int32_t base_vertex,
                                        uint32_t base_instance) {
    if (enc == NULL || index_buffer == NULL) return;
    id<MTLRenderCommandEncoder> e = (__bridge id<MTLRenderCommandEncoder>)enc;
    [e drawIndexedPrimitives:(MTLPrimitiveType)primitive
                  indexCount:index_count
                   indexType:(MTLIndexType)index_type
                 indexBuffer:(__bridge id<MTLBuffer>)index_buffer
           indexBufferOffset:(NSUInteger)index_offset
               instanceCount:instance_count
                  baseVertex:base_vertex
                baseInstance:base_instance];
}

/* -- blit encoders ---------------------------------------------------------------------- */

FdMtlBlitEncoder *fd_mtl_blit_encoder_begin(FdMtlCommandBuffer *cb) {
    if (cb == NULL) return NULL;
    @autoreleasepool {
        id<MTLCommandBuffer> c = (__bridge id<MTLCommandBuffer>)cb;
        id<MTLBlitCommandEncoder> enc = [c blitCommandEncoder];
        if (enc == nil) return NULL;
        return (__bridge_retained FdMtlBlitEncoder *)enc;
    }
}

void fd_mtl_blit_encoder_end(FdMtlBlitEncoder *enc) {
    if (enc == NULL) return;
    id<MTLBlitCommandEncoder> e = (__bridge id<MTLBlitCommandEncoder>)enc;
    [e endEncoding];
}

void fd_mtl_blit_encoder_destroy(FdMtlBlitEncoder *enc) {
    if (enc == NULL) return;
    id<MTLBlitCommandEncoder> e = (__bridge_transfer id<MTLBlitCommandEncoder>)enc;
    (void)e;
}

void fd_mtl_blit_copy_buffer(FdMtlBlitEncoder *enc, FdMtlBuffer *src, uint64_t src_offset,
                             FdMtlBuffer *dst, uint64_t dst_offset, uint64_t size) {
    if (enc == NULL || src == NULL || dst == NULL || size == 0) return;
    id<MTLBlitCommandEncoder> e = (__bridge id<MTLBlitCommandEncoder>)enc;
    [e copyFromBuffer:(__bridge id<MTLBuffer>)src
         sourceOffset:(NSUInteger)src_offset
             toBuffer:(__bridge id<MTLBuffer>)dst
    destinationOffset:(NSUInteger)dst_offset
                 size:(NSUInteger)size];
}

void fd_mtl_blit_copy_buffer_to_texture(FdMtlBlitEncoder *enc, FdMtlBuffer *src,
                                        uint64_t src_offset, uint32_t bytes_per_row,
                                        FdMtlTexture *dst, uint32_t mip_level,
                                        uint32_t width, uint32_t height) {
    if (enc == NULL || src == NULL || dst == NULL) return;
    id<MTLBlitCommandEncoder> e = (__bridge id<MTLBlitCommandEncoder>)enc;
    [e copyFromBuffer:(__bridge id<MTLBuffer>)src
         sourceOffset:(NSUInteger)src_offset
    sourceBytesPerRow:bytes_per_row
  sourceBytesPerImage:(NSUInteger)bytes_per_row * height
           sourceSize:MTLSizeMake(width, height, 1)
            toTexture:(__bridge id<MTLTexture>)dst
     destinationSlice:0
     destinationLevel:mip_level
    destinationOrigin:MTLOriginMake(0, 0, 0)];
}
