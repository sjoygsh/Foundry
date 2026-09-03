/*
 * Foundry's Metal bridge: the C surface the Zig backend calls (ADR-0012).
 *
 * This header is deliberately boring. It mirrors Metal roughly one-to-one and holds **no
 * policy**: no caching, no state machine, no defaults, no decisions. Every design choice —
 * pipeline caching, resource lifetime strategy, submission scheduling, how an abstract bind
 * group becomes an argument table index — lives in the Zig backend above it. If a function
 * here starts deciding something, that logic is in the wrong place; the shim growing a
 * decision is the signal to move it up.
 *
 * Two consequences of that rule are visible throughout:
 *
 *   - **Enumerations are Metal's own numeric values**, passed as `uint32_t`. The shim does
 *     not translate Foundry's formats, blend factors or load actions into Metal's; the Zig
 *     backend does, because knowing what a `TextureFormat` means is backend knowledge and
 *     translating it here would make this file a second, hidden mapping table.
 *
 *   - **Every object is an opaque pointer with exactly one matching destroy.** Nothing about
 *     Metal's type system reaches Zig and nothing about Zig's reaches here. Objective-C
 *     lifetime stays in Objective-C, where ARC handles it; a handle returned across this
 *     boundary is retained, and its destroy is the release.
 *
 * This is also a C ABI boundary *inside* the engine, which is the point: it exercises the
 * same discipline ADR-0004 requires of the public API on a smaller, lower-risk surface,
 * years before the public ABI is built.
 */

#ifndef FOUNDRY_METAL_SHIM_H
#define FOUNDRY_METAL_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -- Metal's own enumeration values -------------------------------------------------- */

/*
 * The shim takes Metal's numbers, not Foundry's, so that it stays a mirror rather than
 * becoming a second hidden mapping table. Those numbers have to be written somewhere the
 * Zig backend can read, and Zig cannot parse Objective-C headers — so they are declared
 * here and **every one is `_Static_assert`ed against the real `MTL*` value** in
 * `metal_shim.m`.
 *
 * That assertion is the point of doing it this way. A wrong constant here would not fail:
 * it would render something subtly incorrect, on one backend, with no error anywhere. This
 * turns that into a build failure. `MTLColorWriteMask` is the standing example of why —
 * red is `1 << 3` and alpha is `1 << 0`, the reverse of the obvious guess.
 */
enum {
    FD_MTL_PIXEL_FORMAT_INVALID = 0,
    FD_MTL_PIXEL_FORMAT_R8_UNORM = 10,
    FD_MTL_PIXEL_FORMAT_R16_FLOAT = 25,
    FD_MTL_PIXEL_FORMAT_RG8_UNORM = 30,
    FD_MTL_PIXEL_FORMAT_R32_FLOAT = 55,
    FD_MTL_PIXEL_FORMAT_RGBA8_UNORM = 70,
    FD_MTL_PIXEL_FORMAT_RGBA8_UNORM_SRGB = 71,
    FD_MTL_PIXEL_FORMAT_BGRA8_UNORM = 80,
    FD_MTL_PIXEL_FORMAT_BGRA8_UNORM_SRGB = 81,
    FD_MTL_PIXEL_FORMAT_RGBA16_FLOAT = 115,
    FD_MTL_PIXEL_FORMAT_RGBA32_FLOAT = 125,
    FD_MTL_PIXEL_FORMAT_DEPTH32_FLOAT = 252,
    FD_MTL_PIXEL_FORMAT_DEPTH32_FLOAT_STENCIL8 = 260,

    FD_MTL_VERTEX_FORMAT_UCHAR4 = 3,
    FD_MTL_VERTEX_FORMAT_UCHAR4_NORMALIZED = 9,
    FD_MTL_VERTEX_FORMAT_USHORT2 = 13,
    FD_MTL_VERTEX_FORMAT_FLOAT = 28,
    FD_MTL_VERTEX_FORMAT_FLOAT2 = 29,
    FD_MTL_VERTEX_FORMAT_FLOAT3 = 30,
    FD_MTL_VERTEX_FORMAT_FLOAT4 = 31,
    FD_MTL_VERTEX_FORMAT_UINT = 36,

    FD_MTL_INDEX_TYPE_UINT16 = 0,
    FD_MTL_INDEX_TYPE_UINT32 = 1,

    FD_MTL_LOAD_ACTION_DONT_CARE = 0,
    FD_MTL_LOAD_ACTION_LOAD = 1,
    FD_MTL_LOAD_ACTION_CLEAR = 2,

    FD_MTL_STORE_ACTION_DONT_CARE = 0,
    FD_MTL_STORE_ACTION_STORE = 1,

    FD_MTL_STORAGE_MODE_SHARED = 0,
    FD_MTL_STORAGE_MODE_MANAGED = 1,
    FD_MTL_STORAGE_MODE_PRIVATE = 2,

    /* `MTLResourceOptions` places the storage mode at bit 4. */
    FD_MTL_RESOURCE_STORAGE_MODE_SHARED = 0 << 4,
    FD_MTL_RESOURCE_STORAGE_MODE_MANAGED = 1 << 4,
    FD_MTL_RESOURCE_STORAGE_MODE_PRIVATE = 2 << 4,

    FD_MTL_TEXTURE_USAGE_SHADER_READ = 0x1,
    FD_MTL_TEXTURE_USAGE_SHADER_WRITE = 0x2,
    FD_MTL_TEXTURE_USAGE_RENDER_TARGET = 0x4,

    FD_MTL_PRIMITIVE_TYPE_POINT = 0,
    FD_MTL_PRIMITIVE_TYPE_LINE = 1,
    FD_MTL_PRIMITIVE_TYPE_LINE_STRIP = 2,
    FD_MTL_PRIMITIVE_TYPE_TRIANGLE = 3,
    FD_MTL_PRIMITIVE_TYPE_TRIANGLE_STRIP = 4,

    FD_MTL_CULL_MODE_NONE = 0,
    FD_MTL_CULL_MODE_FRONT = 1,
    FD_MTL_CULL_MODE_BACK = 2,

    FD_MTL_WINDING_CLOCKWISE = 0,
    FD_MTL_WINDING_COUNTER_CLOCKWISE = 1,

    FD_MTL_COMPARE_NEVER = 0,
    FD_MTL_COMPARE_LESS = 1,
    FD_MTL_COMPARE_EQUAL = 2,
    FD_MTL_COMPARE_LESS_EQUAL = 3,
    FD_MTL_COMPARE_GREATER = 4,
    FD_MTL_COMPARE_NOT_EQUAL = 5,
    FD_MTL_COMPARE_GREATER_EQUAL = 6,
    FD_MTL_COMPARE_ALWAYS = 7,

    FD_MTL_BLEND_FACTOR_ZERO = 0,
    FD_MTL_BLEND_FACTOR_ONE = 1,
    FD_MTL_BLEND_FACTOR_SRC_COLOR = 2,
    FD_MTL_BLEND_FACTOR_ONE_MINUS_SRC_COLOR = 3,
    FD_MTL_BLEND_FACTOR_SRC_ALPHA = 4,
    FD_MTL_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA = 5,
    FD_MTL_BLEND_FACTOR_DST_COLOR = 6,
    FD_MTL_BLEND_FACTOR_ONE_MINUS_DST_COLOR = 7,
    FD_MTL_BLEND_FACTOR_DST_ALPHA = 8,
    FD_MTL_BLEND_FACTOR_ONE_MINUS_DST_ALPHA = 9,

    FD_MTL_BLEND_OP_ADD = 0,
    FD_MTL_BLEND_OP_SUBTRACT = 1,
    FD_MTL_BLEND_OP_REVERSE_SUBTRACT = 2,
    FD_MTL_BLEND_OP_MIN = 3,
    FD_MTL_BLEND_OP_MAX = 4,

    /* Note the order: red is the high bit and alpha the low one. */
    FD_MTL_COLOR_WRITE_MASK_NONE = 0,
    FD_MTL_COLOR_WRITE_MASK_ALPHA = 0x1 << 0,
    FD_MTL_COLOR_WRITE_MASK_BLUE = 0x1 << 1,
    FD_MTL_COLOR_WRITE_MASK_GREEN = 0x1 << 2,
    FD_MTL_COLOR_WRITE_MASK_RED = 0x1 << 3,
    FD_MTL_COLOR_WRITE_MASK_ALL = 0xf,

    FD_MTL_SAMPLER_FILTER_NEAREST = 0,
    FD_MTL_SAMPLER_FILTER_LINEAR = 1,
    FD_MTL_SAMPLER_MIP_NOT_MIPMAPPED = 0,
    FD_MTL_SAMPLER_MIP_NEAREST = 1,
    FD_MTL_SAMPLER_MIP_LINEAR = 2,
    FD_MTL_SAMPLER_ADDRESS_CLAMP_TO_EDGE = 0,
    FD_MTL_SAMPLER_ADDRESS_REPEAT = 2,
    FD_MTL_SAMPLER_ADDRESS_MIRROR_REPEAT = 3,

    FD_MTL_VERTEX_STEP_PER_VERTEX = 1,
    FD_MTL_VERTEX_STEP_PER_INSTANCE = 2
};

/* -- objects ------------------------------------------------------------------------ */

typedef struct FdMtlDevice FdMtlDevice;
typedef struct FdMtlQueue FdMtlQueue;
typedef struct FdMtlBuffer FdMtlBuffer;
typedef struct FdMtlTexture FdMtlTexture;
typedef struct FdMtlSampler FdMtlSampler;
typedef struct FdMtlLibrary FdMtlLibrary;
typedef struct FdMtlFunction FdMtlFunction;
typedef struct FdMtlRenderPipeline FdMtlRenderPipeline;
typedef struct FdMtlDepthState FdMtlDepthState;
typedef struct FdMtlCommandBuffer FdMtlCommandBuffer;
typedef struct FdMtlRenderEncoder FdMtlRenderEncoder;
typedef struct FdMtlBlitEncoder FdMtlBlitEncoder;
typedef struct FdMtlDrawable FdMtlDrawable;

/* -- device ------------------------------------------------------------------------- */

/* NULL if the machine has no Metal device. Not an assertion: a headless build machine or a
 * stripped VM is a configuration Foundry should report, not crash on. */
FdMtlDevice *fd_mtl_device_create(void);
void fd_mtl_device_destroy(FdMtlDevice *dev);

/* Copies a NUL-terminated name into `out`, truncating to `cap`. Returns the length written,
 * or -1 if `cap` is not positive. */
int32_t fd_mtl_device_name(FdMtlDevice *dev, char *out, int32_t cap);

bool fd_mtl_device_has_unified_memory(FdMtlDevice *dev);

/* Largest 2D texture dimension the device supports, derived from its GPU family. */
uint32_t fd_mtl_device_max_texture_dimension(FdMtlDevice *dev);

/* -- queue -------------------------------------------------------------------------- */

FdMtlQueue *fd_mtl_queue_create(FdMtlDevice *dev, const char *label);
void fd_mtl_queue_destroy(FdMtlQueue *queue);

/* -- layer and drawables ------------------------------------------------------------- */

/*
 * `layer` is a `CAMetalLayer *` produced by the platform layer and handed across as an
 * opaque pointer (`platform.NativeSurfaceHandle`). The shim is the first place that knows
 * what it actually is; `platform` does not know Metal exists and `rhi` above this file does
 * not know SDL does.
 */
void fd_mtl_layer_configure(void *layer, FdMtlDevice *dev, uint32_t pixel_format,
                            uint32_t width, uint32_t height, bool vsync);

/* The layer's current pixel format, as an `MTLPixelFormat` value. */
uint32_t fd_mtl_layer_pixel_format(void *layer);

/* NULL when the layer has no drawable available — a minimised or off-screen window, or all
 * drawables still in flight. The caller decides what that means; the shim does not. */
FdMtlDrawable *fd_mtl_layer_next_drawable(void *layer);
void fd_mtl_drawable_destroy(FdMtlDrawable *drawable);

/* A retained handle to the drawable's texture. Destroy it like any other texture. */
FdMtlTexture *fd_mtl_drawable_texture(FdMtlDrawable *drawable);

/* -- buffers ------------------------------------------------------------------------- */

/* `resource_options` is an `MTLResourceOptions` bitmask. */
FdMtlBuffer *fd_mtl_buffer_create(FdMtlDevice *dev, uint64_t length,
                                  uint32_t resource_options, const char *label);
void fd_mtl_buffer_destroy(FdMtlBuffer *buffer);

/* NULL for a private-storage buffer, which has no CPU-visible contents. */
void *fd_mtl_buffer_contents(FdMtlBuffer *buffer);

/* Required for managed storage on discrete GPUs; a no-op for shared storage. Called
 * unconditionally by the backend so the code path does not differ per machine. */
void fd_mtl_buffer_did_modify_range(FdMtlBuffer *buffer, uint64_t offset, uint64_t length);

/* -- textures ------------------------------------------------------------------------ */

typedef struct FdMtlTextureDesc {
    uint32_t pixel_format; /* MTLPixelFormat */
    uint32_t width;
    uint32_t height;
    uint32_t mip_levels;
    uint32_t usage;        /* MTLTextureUsage bitmask */
    uint32_t storage_mode; /* MTLStorageMode */
} FdMtlTextureDesc;

FdMtlTexture *fd_mtl_texture_create(FdMtlDevice *dev, const FdMtlTextureDesc *desc,
                                    const char *label);
void fd_mtl_texture_destroy(FdMtlTexture *texture);
uint32_t fd_mtl_texture_width(FdMtlTexture *texture);
uint32_t fd_mtl_texture_height(FdMtlTexture *texture);

/* -- samplers ------------------------------------------------------------------------ */

typedef struct FdMtlSamplerDesc {
    uint32_t min_filter; /* MTLSamplerMinMagFilter */
    uint32_t mag_filter; /* MTLSamplerMinMagFilter */
    uint32_t mip_filter; /* MTLSamplerMipFilter */
    uint32_t address_u;  /* MTLSamplerAddressMode */
    uint32_t address_v;  /* MTLSamplerAddressMode */
} FdMtlSamplerDesc;

FdMtlSampler *fd_mtl_sampler_create(FdMtlDevice *dev, const FdMtlSamplerDesc *desc,
                                    const char *label);
void fd_mtl_sampler_destroy(FdMtlSampler *sampler);

/* -- shader libraries ---------------------------------------------------------------- */

/*
 * Both return NULL on failure, writing a NUL-terminated compiler diagnostic into `err`.
 * The message matters: a shader that fails to compile at runtime is the hot-reload path
 * (ADR-0015), and an author needs the compiler's own words, not "compilation failed".
 */
FdMtlLibrary *fd_mtl_library_from_data(FdMtlDevice *dev, const void *bytes, size_t len,
                                       char *err, int32_t err_cap);
FdMtlLibrary *fd_mtl_library_from_source(FdMtlDevice *dev, const char *source,
                                         char *err, int32_t err_cap);
void fd_mtl_library_destroy(FdMtlLibrary *library);

/* NULL if the library declares no function by that name. */
FdMtlFunction *fd_mtl_library_function(FdMtlLibrary *library, const char *name);
void fd_mtl_function_destroy(FdMtlFunction *function);

/* -- render pipelines ---------------------------------------------------------------- */

typedef struct FdMtlVertexAttribute {
    uint32_t location;     /* attribute index the shader declares */
    uint32_t format;       /* MTLVertexFormat */
    uint32_t offset;
    uint32_t buffer_index; /* Metal buffer index, already flattened by the backend */
} FdMtlVertexAttribute;

typedef struct FdMtlVertexBufferLayout {
    uint32_t buffer_index;
    uint32_t stride;
    uint32_t step_function; /* MTLVertexStepFunction */
} FdMtlVertexBufferLayout;

typedef struct FdMtlColorTarget {
    uint32_t pixel_format; /* MTLPixelFormat */
    bool blending_enabled;
    uint32_t src_rgb;      /* MTLBlendFactor */
    uint32_t dst_rgb;
    uint32_t rgb_op;       /* MTLBlendOperation */
    uint32_t src_alpha;
    uint32_t dst_alpha;
    uint32_t alpha_op;
    uint32_t write_mask;   /* MTLColorWriteMask */
} FdMtlColorTarget;

typedef struct FdMtlRenderPipelineDesc {
    FdMtlFunction *vertex_function;
    FdMtlFunction *fragment_function;

    const FdMtlVertexAttribute *attributes;
    uint32_t attribute_count;
    const FdMtlVertexBufferLayout *vertex_layouts;
    uint32_t vertex_layout_count;

    const FdMtlColorTarget *color_targets;
    uint32_t color_target_count;

    /* MTLPixelFormatInvalid (0) when the pipeline has no depth attachment. */
    uint32_t depth_pixel_format;

    const char *label;
} FdMtlRenderPipelineDesc;

FdMtlRenderPipeline *fd_mtl_render_pipeline_create(FdMtlDevice *dev,
                                                   const FdMtlRenderPipelineDesc *desc,
                                                   char *err, int32_t err_cap);
void fd_mtl_render_pipeline_destroy(FdMtlRenderPipeline *pipeline);

typedef struct FdMtlDepthStateDesc {
    uint32_t compare; /* MTLCompareFunction */
    bool write_enabled;
} FdMtlDepthStateDesc;

FdMtlDepthState *fd_mtl_depth_state_create(FdMtlDevice *dev, const FdMtlDepthStateDesc *desc);
void fd_mtl_depth_state_destroy(FdMtlDepthState *state);

/* -- command buffers ------------------------------------------------------------------ */

FdMtlCommandBuffer *fd_mtl_command_buffer_create(FdMtlQueue *queue, const char *label);
void fd_mtl_command_buffer_destroy(FdMtlCommandBuffer *cb);
void fd_mtl_command_buffer_present(FdMtlCommandBuffer *cb, FdMtlDrawable *drawable);
void fd_mtl_command_buffer_commit(FdMtlCommandBuffer *cb);

/* Blocks until the GPU has finished this command buffer. Returns immediately if it already
 * has. This is how the backend enforces the frame ring: a slot waits on the command buffer
 * that last used it. */
void fd_mtl_command_buffer_wait_until_completed(FdMtlCommandBuffer *cb);

/* -- render encoders ------------------------------------------------------------------ */

typedef struct FdMtlColorAttachment {
    FdMtlTexture *texture;
    uint32_t load_action;  /* MTLLoadAction */
    uint32_t store_action; /* MTLStoreAction */
    double clear_r;
    double clear_g;
    double clear_b;
    double clear_a;
} FdMtlColorAttachment;

typedef struct FdMtlDepthAttachment {
    FdMtlTexture *texture;
    uint32_t load_action;
    uint32_t store_action;
    double clear_depth;
} FdMtlDepthAttachment;

typedef struct FdMtlRenderPassDesc {
    const FdMtlColorAttachment *color;
    uint32_t color_count;
    /* NULL when the pass has no depth attachment. */
    const FdMtlDepthAttachment *depth;
    const char *label;
} FdMtlRenderPassDesc;

FdMtlRenderEncoder *fd_mtl_render_encoder_begin(FdMtlCommandBuffer *cb,
                                                const FdMtlRenderPassDesc *desc);
void fd_mtl_render_encoder_end(FdMtlRenderEncoder *enc);
void fd_mtl_render_encoder_destroy(FdMtlRenderEncoder *enc);

void fd_mtl_render_encoder_set_pipeline(FdMtlRenderEncoder *enc, FdMtlRenderPipeline *pso);
void fd_mtl_render_encoder_set_depth_state(FdMtlRenderEncoder *enc, FdMtlDepthState *state);
void fd_mtl_render_encoder_set_cull_mode(FdMtlRenderEncoder *enc, uint32_t mode);
void fd_mtl_render_encoder_set_front_face(FdMtlRenderEncoder *enc, uint32_t winding);
void fd_mtl_render_encoder_set_viewport(FdMtlRenderEncoder *enc, double x, double y,
                                        double width, double height,
                                        double znear, double zfar);
void fd_mtl_render_encoder_set_scissor(FdMtlRenderEncoder *enc, uint32_t x, uint32_t y,
                                       uint32_t width, uint32_t height);

void fd_mtl_render_encoder_set_vertex_buffer(FdMtlRenderEncoder *enc, FdMtlBuffer *buffer,
                                             uint64_t offset, uint32_t index);
void fd_mtl_render_encoder_set_vertex_bytes(FdMtlRenderEncoder *enc, const void *bytes,
                                            size_t len, uint32_t index);
void fd_mtl_render_encoder_set_vertex_texture(FdMtlRenderEncoder *enc, FdMtlTexture *texture,
                                              uint32_t index);
void fd_mtl_render_encoder_set_vertex_sampler(FdMtlRenderEncoder *enc, FdMtlSampler *sampler,
                                              uint32_t index);

void fd_mtl_render_encoder_set_fragment_buffer(FdMtlRenderEncoder *enc, FdMtlBuffer *buffer,
                                               uint64_t offset, uint32_t index);
void fd_mtl_render_encoder_set_fragment_bytes(FdMtlRenderEncoder *enc, const void *bytes,
                                              size_t len, uint32_t index);
void fd_mtl_render_encoder_set_fragment_texture(FdMtlRenderEncoder *enc,
                                                FdMtlTexture *texture, uint32_t index);
void fd_mtl_render_encoder_set_fragment_sampler(FdMtlRenderEncoder *enc,
                                                FdMtlSampler *sampler, uint32_t index);

void fd_mtl_render_encoder_draw(FdMtlRenderEncoder *enc, uint32_t primitive,
                                uint32_t vertex_start, uint32_t vertex_count,
                                uint32_t instance_count, uint32_t base_instance);
void fd_mtl_render_encoder_draw_indexed(FdMtlRenderEncoder *enc, uint32_t primitive,
                                        uint32_t index_count, uint32_t index_type,
                                        FdMtlBuffer *index_buffer, uint64_t index_offset,
                                        uint32_t instance_count, int32_t base_vertex,
                                        uint32_t base_instance);

/* -- blit encoders -------------------------------------------------------------------- */

FdMtlBlitEncoder *fd_mtl_blit_encoder_begin(FdMtlCommandBuffer *cb);
void fd_mtl_blit_encoder_end(FdMtlBlitEncoder *enc);
void fd_mtl_blit_encoder_destroy(FdMtlBlitEncoder *enc);

void fd_mtl_blit_copy_buffer(FdMtlBlitEncoder *enc, FdMtlBuffer *src, uint64_t src_offset,
                             FdMtlBuffer *dst, uint64_t dst_offset, uint64_t size);
void fd_mtl_blit_copy_buffer_to_texture(FdMtlBlitEncoder *enc, FdMtlBuffer *src,
                                        uint64_t src_offset, uint32_t bytes_per_row,
                                        FdMtlTexture *dst, uint32_t mip_level,
                                        uint32_t width, uint32_t height);

#ifdef __cplusplus
}
#endif

#endif /* FOUNDRY_METAL_SHIM_H */
