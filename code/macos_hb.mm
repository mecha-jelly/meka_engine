/*
 * Written by Gyuhyun Lee
 */

#include <Cocoa/Cocoa.h> // APPKIT
#include <CoreGraphics/CoreGraphics.h> 
#include <mach/mach_time.h> // mach_absolute_time
#include <stdio.h> // printf for debugging purpose
#include <sys/stat.h>
#include <libkern/OSAtomic.h>
#include <pthread.h>
#include <semaphore.h>
#include <Carbon/Carbon.h>
#include <dlfcn.h> // dlsym
#include <metalkit/metalkit.h>
#include <metal/metal.h>

// TODO(gh) introspection?
#undef internal
#undef assert

// TODO(gh) shared.h file for files that are shared across platforms?
#include "hb_types.h"
#include "hb_intrinsic.h"
#include "hb_platform.h"
#include "hb_math.h"
#include "hb_random.h"
#include "hb_simd.h"
#include "hb_render_group.h"

#include "hb_metal.cpp"
#include "hb_render_group.cpp"

// TODO(gh): Get rid of global variables?
global v2 last_mouse_p;
global v2 mouse_diff;

global b32 is_game_running;
global dispatch_semaphore_t semaphore;

internal u64 
mach_time_diff_in_nano_seconds(u64 begin, u64 end, f32 nano_seconds_per_tick)
{
    return (u64)(((end - begin)*nano_seconds_per_tick));
}

PLATFORM_GET_FILE_SIZE(macos_get_file_size) 
{
    u64 result = 0;

    int File = open(filename, O_RDONLY);
    struct stat FileStat;
    fstat(File , &FileStat); 
    result = FileStat.st_size;
    close(File);

    return result;
}

PLATFORM_READ_FILE(debug_macos_read_file)
{
    PlatformReadFileResult Result = {};

    int File = open(filename, O_RDONLY);
    int Error = errno;
    if(File >= 0) // NOTE : If the open() succeded, the return value is non-negative value.
    {
        struct stat FileStat;
        fstat(File , &FileStat); 
        off_t fileSize = FileStat.st_size;

        if(fileSize > 0)
        {
            // TODO/gh : no more os level allocations!
            Result.size = fileSize;
            Result.memory = (u8 *)malloc(Result.size);
            if(read(File, Result.memory, fileSize) == -1)
            {
                free(Result.memory);
                Result.size = 0;
            }
        }

        close(File);
    }

    return Result;
}

PLATFORM_WRITE_ENTIRE_FILE(debug_macos_write_entire_file)
{
    int file = open(file_name, O_WRONLY|O_CREAT|O_TRUNC, S_IRWXU);

    if(file >= 0) 
    {
        if(write(file, memory_to_write, size) == -1)
        {
            // TODO(gh) : log
        }

        close(file);
    }
    else
    {
        // TODO(gh) :log
        printf("Failed to create file\n");
    }
}

PLATFORM_FREE_FILE_MEMORY(debug_macos_free_file_memory)
{
    free(memory);
}

@interface 
app_delegate : NSObject<NSApplicationDelegate>
@end
@implementation app_delegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    [NSApp stop:nil];

    // Post empty event: without it we can't put application to front
    // for some reason (I get this technique from GLFW source).
    NSAutoreleasePool* pool = [NSAutoreleasePool new];
    NSEvent* event =
        [NSEvent otherEventWithType: NSApplicationDefined
                 location: NSMakePoint(0, 0)
                 modifierFlags: 0
                 timestamp: 0
                 windowNumber: 0
                 context: nil
                 subtype: 0
                 data1: 0
                 data2: 0];
    [NSApp postEvent: event atStart: YES];
    [pool drain];
}

@end

internal CVReturn 
display_link_callback(CVDisplayLinkRef displayLink, const CVTimeStamp* current_time, const CVTimeStamp* output_time,
                CVOptionFlags ignored_0, CVOptionFlags* ignored_1, void* displayLinkContext)
{
    local_persist u64 last_time = 0;
    u64 time_passed_in_nsec = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - last_time;
    u64 time_until_output = output_time->hostTime - last_time;

    // printf("%lldns time passed, %lldns until output\n", time_passed_in_nsec, time_until_output);

    last_time = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    return kCVReturnSuccess;
}

internal void
macos_handle_event(NSApplication *app, NSWindow *window, PlatformInput *platform_input)
{
    NSPoint mouse_location = [NSEvent mouseLocation];
    NSRect frame_rect = [window frame];
    NSRect content_rect = [window contentLayoutRect];

    v2 bottom_left_p = {};
    bottom_left_p.x = frame_rect.origin.x;
    bottom_left_p.y = frame_rect.origin.y;

    v2 content_rect_dim = {}; 
    content_rect_dim.x = content_rect.size.width; 
    content_rect_dim.y = content_rect.size.height;

    v2 rel_mouse_location = {};
    rel_mouse_location.x = mouse_location.x - bottom_left_p.x;
    rel_mouse_location.y = mouse_location.y - bottom_left_p.y;

    f32 mouse_speed_when_clipped = 0.08f;
    if(rel_mouse_location.x >= 0.0f && rel_mouse_location.x < content_rect_dim.x)
    {
        mouse_diff.x = mouse_location.x - last_mouse_p.x;
    }
    else if(rel_mouse_location.x < 0.0f)
    {
        mouse_diff.x = -mouse_speed_when_clipped;
    }
    else
    {
        mouse_diff.x = mouse_speed_when_clipped;
    }

    if(rel_mouse_location.y >= 0.0f && rel_mouse_location.y < content_rect_dim.y)
    {
        mouse_diff.y = mouse_location.y - last_mouse_p.y;
    }
    else if(rel_mouse_location.y < 0.0f)
    {
        mouse_diff.y = -mouse_speed_when_clipped;
    }
    else
    {
        mouse_diff.y = mouse_speed_when_clipped;
    }

    // NOTE(gh) : MacOS screen coordinate is bottom-up, so just for the convenience, make y to be bottom-up
    mouse_diff.y *= -1.0f;

    last_mouse_p.x = mouse_location.x;
    last_mouse_p.y = mouse_location.y;

    //printf("%f, %f\n", mouse_diff.x, mouse_diff.y);

    // TODO : Check if this loop has memory leak.
    while(1)
    {
        NSEvent *event = [app nextEventMatchingMask:NSAnyEventMask
                         untilDate:nil
                            inMode:NSDefaultRunLoopMode
                           dequeue:YES];
        if(event)
        {
            switch([event type])
            {
                case NSEventTypeKeyUp:
                case NSEventTypeKeyDown:
                {
                    b32 was_down = event.ARepeat;
                    b32 is_down = ([event type] == NSEventTypeKeyDown);

                    if((is_down != was_down) || !is_down)
                    {
                        //printf("isDown : %d, WasDown : %d", is_down, was_down);
                        u16 key_code = [event keyCode];
                        if(key_code == kVK_Escape)
                        {
                            is_game_running = false;
                        }
                        else if(key_code == kVK_ANSI_W)
                        {
                            platform_input->move_up = is_down;
                        }
                        else if(key_code == kVK_ANSI_A)
                        {
                            platform_input->move_left = is_down;
                        }
                        else if(key_code == kVK_ANSI_S)
                        {
                            platform_input->move_down = is_down;
                        }
                        else if(key_code == kVK_ANSI_D)
                        {
                            platform_input->move_right = is_down;
                        }

                        else if(key_code == kVK_ANSI_I)
                        {
                            platform_input->action_up = is_down;
                        }
                        else if(key_code == kVK_ANSI_J)
                        {
                            platform_input->action_left = is_down;
                        }
                        else if(key_code == kVK_ANSI_K)
                        {
                            platform_input->action_down = is_down;
                        }
                        else if(key_code == kVK_ANSI_L)
                        {
                            platform_input->action_right = is_down;
                        }

                        else if(key_code == kVK_LeftArrow)
                        {
                            platform_input->action_left = is_down;
                        }
                        else if(key_code == kVK_RightArrow)
                        {
                            platform_input->action_right = is_down;
                        }
                        else if(key_code == kVK_UpArrow)
                        {
                            platform_input->action_up = is_down;
                        }
                        else if(key_code == kVK_DownArrow)
                        {
                            platform_input->action_down = is_down;
                        }

                        else if(key_code == kVK_Space)
                        {
                            platform_input->space = is_down;
                        }

                        else if(key_code == kVK_Return)
                        {
                            if(is_down)
                            {
                                NSWindow *window = [event window];
                                // TODO : proper buffer resize here!
                                [window toggleFullScreen:0];
                            }
                        }
                    }
                }break;

                default:
                {
                    [app sendEvent : event];
                }
            }
        }
        else
        {
            break;
        }
    }
} 

// TODO(gh) : It seems like this combines read & write barrier, but make sure
// TODO(gh) : mfence?(DSB)
#define write_barrier() OSMemoryBarrier(); 
#define read_barrier() OSMemoryBarrier();

struct macos_thread
{
    u32 ID;
    ThreadWorkQueue *queue;

    // TODO(gh): I like the idea of each thread having a random number generator that they can use throughout the whole process
    // though what should happen to the 0th thread(which does not have this structure)?
    simd_random_series series;
};

// NOTE(gh) : use this to add what thread should do
internal 
THREAD_WORK_CALLBACK(print_string)
{
    char *stringToPrint = (char *)data;
    printf("%s\n", stringToPrint);
}

// NOTE(gh): This is single producer multiple consumer - 
// meaning, it _does not_ provide any thread safety
// For example, if the two threads try to add the work item,
// one item might end up over-writing the other one
internal void
macos_add_thread_work_item(ThreadWorkQueue *queue,
                            ThreadWorkCallback *work_callback,
                            void *data)
{
    assert(data); // TODO(gh) : There might be a work that does not need any data?
    thread_work_item *item = queue->items + queue->add_index;
    item->callback = work_callback;
    item->data = data;
    item->written = true;

    write_barrier();
    queue->add_index++;

    // increment the semaphore value by 1
    dispatch_semaphore_signal(semaphore);
}

internal b32
macos_do_thread_work_item(ThreadWorkQueue *queue, u32 thread_index)
{
    b32 did_work = false;
    if(queue->work_index != queue->add_index)
    {
        int original_work_index = queue->work_index;
        int desired_work_index = original_work_index + 1;

        if(OSAtomicCompareAndSwapIntBarrier(original_work_index, desired_work_index, &queue->work_index))
        {
            thread_work_item *item = queue->items + original_work_index;
            item->callback(item->data);

            //printf("Thread %u: Finished working\n", thread_index);
            did_work = true;
        }
    }

    return did_work;
}

internal 
PLATFORM_COMPLETE_ALL_THREAD_WORK_QUEUE_ITEMS(macos_complete_all_ThreadWorkQueue_items)
{
    // TODO(gh): If there was a last thread that was working on the item,
    // this does not guarantee that the last work will be finished.
    // Maybe add some flag inside the thread? (sleep / working / ...)
    while(queue->work_index != queue->add_index) 
    {
        macos_do_thread_work_item(queue, 0);
    }
}

internal void*
thread_proc(void *data)
{
    macos_thread *thread = (macos_thread *)data;
    while(1)
    {
        if(macos_do_thread_work_item(thread->queue, thread->ID))
        {
        }
        else
        {
            // dispatch semaphore puts the thread into sleep until the semaphore is signaled
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        }
    }

    return 0;
}

// TODO(gh) Later, we can make this to also 'stream' the meshes(just like the other assets), 
// and put them inside the render mesh so that the graphics API can render them.
internal void
metal_render_and_wait_until_completion(MetalRenderContext *render_context, PlatformRenderPushBuffer *render_push_buffer, u32 window_width, u32 window_height, f32 dt_per_frame)
{
    // Update gpu side of combined vertex and index buffer
    // TODO(gh) Do we need to sync before we render??
    metal_flush_managed_buffer(&render_context->combined_vertex_buffer, render_push_buffer->used_vertex_buffer);
    metal_flush_managed_buffer(&render_context->combined_index_buffer, render_push_buffer->used_index_buffer);

    id<MTLCommandBuffer> shadow_command_buffer = [render_context->command_queue commandBuffer];

    // NOTE(gh) render shadow map
    id<MTLRenderCommandEncoder> shadowmap_render_encoder = [shadow_command_buffer renderCommandEncoderWithDescriptor : render_context->directional_light_shadowmap_renderpass];
    metal_set_viewport(shadowmap_render_encoder, 0, 0, 
                       render_context->directional_light_shadowmap_depth_texture_width, 
                       render_context->directional_light_shadowmap_depth_texture_height, 
                       0, 1); // TODO(gh) near and far value when rendering the shadowmap)
    metal_set_scissor_rect(shadowmap_render_encoder, 0, 0, 
                           render_context->directional_light_shadowmap_depth_texture_width, 
                           render_context->directional_light_shadowmap_depth_texture_height);
    metal_set_triangle_fill_mode(shadowmap_render_encoder, MTLTriangleFillModeFill);
    metal_set_front_facing_winding(shadowmap_render_encoder, MTLWindingCounterClockwise);
    // Culling front facing triangles when rendering shadowmap to avoid 
    // shadow acne(moire pattern in non-shaded sides). This effectively 'biases' the shadowmap value down
    // TODO(gh) This does not work for thin objects!!!!
    metal_set_cull_mode(shadowmap_render_encoder, MTLCullModeFront); 
    metal_set_detph_stencil_state(shadowmap_render_encoder, render_context->depth_state);

    metal_set_pipeline(shadowmap_render_encoder, render_context->directional_light_shadowmap_pipeline);

    local_persist f32 rad = 2.4f;
    v3 directional_light_p = V3(3 * cosf(rad), 3 * sinf(rad), 50); 
    v3 directional_light_direction = normalize(-directional_light_p); // This will be our -Z in camera for the shadowmap

    // TODO(gh) These are totally made up near, far, width values 
    // m4x4 light_proj = perspective_projection(degree_to_radian(120), 0.01f, 100.0f, (f32)render_context->directional_light_shadowmap_depth_texture_width / (f32)render_context->directional_light_shadowmap_depth_texture_height);
    m4x4 light_proj = orthogonal_projection(0.01f, 100.0f, 10.0f, render_context->directional_light_shadowmap_depth_texture_width / (f32)render_context->directional_light_shadowmap_depth_texture_height);
    v3 directional_light_z_axis = -directional_light_direction;
    v3 directional_light_x_axis = normalize(cross(V3(0, 0, 1), directional_light_z_axis));
    v3 directional_light_y_axis = normalize(cross(directional_light_z_axis, directional_light_x_axis));
    m4x4 light_view = camera_transform(directional_light_p, 
                                       directional_light_x_axis, 
                                       directional_light_y_axis, 
                                       directional_light_z_axis);
    m4x4 light_proj_view = transpose(light_proj * light_view); // Change to column major

    // NOTE(gh) Render Shadow map
    for(u32 consumed = 0;
            consumed < render_push_buffer->used;
            )
    {
        RenderEntryHeader *header = (RenderEntryHeader *)((u8 *)render_push_buffer->base + consumed);

        switch(header->type)
        {
            case RenderEntryType_Line:
            {
                RenderEntryLine *entry = (RenderEntryLine *)((u8 *)render_push_buffer->base + consumed);
                consumed += sizeof(*entry);
            }break;

            case RenderEntryType_AABB:
            {
                RenderEntryAABB *entry = (RenderEntryAABB *)((u8 *)render_push_buffer->base + consumed);
                consumed += sizeof(*entry);

                m4x4 model = st_m4x4(entry->p, entry->dim);
                model = transpose(model); // make the matrix column-major

                metal_set_vertex_buffer(shadowmap_render_encoder, render_context->combined_vertex_buffer.buffer, entry->vertex_buffer_offset, 0);
                metal_set_vertex_bytes(shadowmap_render_encoder, &model, sizeof(model), 1);
                metal_set_vertex_bytes(shadowmap_render_encoder, &light_proj_view, sizeof(light_proj_view), 2);

                // NOTE(gh) Mitigates the moire pattern by biasing, 
                // making the shadow map to place under the fragments that are being shaded.
                // metal_set_depth_bias(shadowmap_render_encoder, 0.015f, 7, 0.02f);

                metal_draw_indexed(shadowmap_render_encoder, MTLPrimitiveTypeTriangle, 
                                  render_context->combined_index_buffer.buffer, entry->index_buffer_offset, entry->index_count);
            }break;

            case RenderEntryType_Grass:
            {
                RenderEntryGrass *entry = (RenderEntryGrass *)((u8 *)render_push_buffer->base + consumed);
                consumed += sizeof(*entry);

#if 0
                m4x4 model = M4x4();
                model = transpose(model); // make the matrix column-major

                metal_set_vertex_buffer(shadowmap_render_encoder, render_context->combined_vertex_buffer.buffer, entry->vertex_buffer_offset, 0);
                metal_set_vertex_bytes(shadowmap_render_encoder, &model, sizeof(model), 1);
                metal_set_vertex_bytes(shadowmap_render_encoder, &light_proj_view, sizeof(light_proj_view), 2);

                // NOTE(gh) Mitigates the moire pattern by biasing, 
                // making the shadow map to place under the fragments that are being shaded.
                // metal_set_depth_bias(shadowmap_render_encoder, 0.015f, 7, 0.02f);
                metal_draw_indexed(shadowmap_render_encoder, MTLPrimitiveTypeTriangle, 
                                  render_context->combined_index_buffer.buffer, entry->index_buffer_offset, entry->index_count);
#endif
            }break;

            default: 
            {
                invalid_code_path;
            }
        }
    }

    metal_end_encoding(shadowmap_render_encoder);
    // We can start working on things that don't require drawable_texture.
    metal_commit_command_buffer(shadow_command_buffer);

    id<MTLCommandBuffer> command_buffer = [render_context->command_queue commandBuffer];
    // TODO(gh) Do we need to sync here?

    // TODO(gh) One downside of thie single pass method is that we cannot do anything if we don't get drawable_texture
    // But in fact, drawing g buffers are independant to getting the drawable_texture.
    id <MTLTexture> drawable_texture =  render_context->view.currentDrawable.texture;
    if(drawable_texture)
    {
        render_context->single_lighting_renderpass.colorAttachments[0].texture = drawable_texture;
        render_context->single_lighting_renderpass.colorAttachments[0].clearColor = {render_push_buffer->clear_color.r,
                                                                                     render_push_buffer->clear_color.g,
                                                                                     render_push_buffer->clear_color.b,
                                                                                     1.0f};

        // TODO(gh) double check whether this thing is freed automatically or not
        // if not, we can pull this outside, and put this inside the render context
        // NOTE(gh) When we create a render_encoder, we cannot create another render encoder until we call endEncoding on the current one.
        id<MTLRenderCommandEncoder> render_encoder = [command_buffer renderCommandEncoderWithDescriptor: render_context->single_lighting_renderpass];

        metal_set_viewport(render_encoder, 0, 0, window_width, window_height, 0, 1);
        metal_set_scissor_rect(render_encoder, 0, 0, window_width, window_height);
        metal_set_triangle_fill_mode(render_encoder, MTLTriangleFillModeFill);
        metal_set_front_facing_winding(render_encoder, MTLWindingCounterClockwise);
        metal_set_detph_stencil_state(render_encoder, render_context->depth_state);

        // TODO(gh) Do we need to 
        PerFrameData per_frame_data = {};

        m4x4 proj = perspective_projection(render_push_buffer->camera_fov, render_push_buffer->camera_near, render_push_buffer->camera_far,
                                           render_push_buffer->width_over_height);

        per_frame_data.proj_view = transpose(proj * render_push_buffer->view);

        // NOTE(gh) per frame data is always the 0th buffer
        metal_set_vertex_bytes(render_encoder, &per_frame_data, sizeof(per_frame_data), 0);
        metal_set_cull_mode(render_encoder, MTLCullModeNone); 

        u32 voxel_instance_count = 0;
        for(u32 consumed = 0;
                consumed < render_push_buffer->used;
                )
        {
            RenderEntryHeader *header = (RenderEntryHeader *)((u8 *)render_push_buffer->base + consumed);

            switch(header->type)
            {
                // TODO(gh) we can also do the similar thing as the voxels,
                // which is allocating the managed buffer and instance-drawing the lines
                case RenderEntryType_Line:
                {
                    RenderEntryLine *entry = (RenderEntryLine *)((u8 *)render_push_buffer->base + consumed);
                    consumed += sizeof(*entry);
#if 0
                    metal_set_pipeline(render_encoder, render_context->line_pipeline);
                    f32 start_and_end[6] = {entry->start.x, entry->start.y, entry->start.z, entry->end.x, entry->end.y, entry->end.z};

                    metal_set_vertex_bytes(render_encoder, start_and_end, sizeof(f32) * array_count(start_and_end), 1);
                    metal_set_vertex_bytes(render_encoder, &entry->color, sizeof(entry->color), 2);

                    metal_draw_non_indexed(render_encoder, MTLPrimitiveTypeLine, 0, 2);
#endif
                }break;

                case RenderEntryType_AABB:
                {
                    RenderEntryAABB *entry = (RenderEntryAABB *)((u8 *)render_push_buffer->base + consumed);
                    consumed += sizeof(*entry);

                    m4x4 model = st_m4x4(entry->p, entry->dim);
                    model = transpose(model); // make the matrix column-major
                    PerObjectData per_object_data = {};
                    per_object_data.model = model;
                    per_object_data.color = entry->color;

                    // TODO(gh) Sort the render entry based on cull mode
                    // metal_set_cull_mode(render_encoder, MTLCullModeBack); 
                    metal_set_pipeline(render_encoder, render_context->singlepass_cube_pipeline);
                    metal_set_vertex_bytes(render_encoder, &per_object_data, sizeof(per_object_data), 1);
                    metal_set_vertex_buffer(render_encoder, 
                                            render_context->combined_vertex_buffer.buffer, 
                                            entry->vertex_buffer_offset, 2);
                    metal_set_vertex_bytes(render_encoder, &light_proj_view, sizeof(light_proj_view), 3);

                    metal_set_fragment_sampler(render_encoder, render_context->shadowmap_sampler, 0);

                    metal_set_fragment_texture(render_encoder, render_context->directional_light_shadowmap_depth_texture, 0);

                    metal_draw_indexed(render_encoder, MTLPrimitiveTypeTriangle, 
                            render_context->combined_index_buffer.buffer, entry->index_buffer_offset, entry->index_count);
                }break;

                // TODO(gh) Use instancing stride to render all the grasses, use seperate pipeline for that without model matrix multiplication)
                case RenderEntryType_Grass:
                {
                    RenderEntryGrass *entry = (RenderEntryGrass *)((u8 *)render_push_buffer->base + consumed);
                    consumed += sizeof(*entry);

                    m4x4 model = M4x4();
                    model = transpose(model); // make the matrix column-major

                    PerObjectData per_object_data = {};
                    per_object_data.model = model;
                    per_object_data.color = entry->color;

                    metal_set_pipeline(render_encoder, render_context->singlepass_cube_pipeline);

                    metal_set_vertex_bytes(render_encoder, &per_object_data, sizeof(per_object_data), 1);
                    metal_set_vertex_buffer(render_encoder, 
                                            render_context->combined_vertex_buffer.buffer, 
                                            entry->vertex_buffer_offset, 2);
                    metal_set_vertex_bytes(render_encoder, &light_proj_view, sizeof(light_proj_view), 3);

                    metal_set_fragment_sampler(render_encoder, render_context->shadowmap_sampler, 0);

                    metal_set_fragment_texture(render_encoder, render_context->directional_light_shadowmap_depth_texture, 0);

                    metal_draw_indexed(render_encoder, MTLPrimitiveTypeTriangle, 
                            render_context->combined_index_buffer.buffer, entry->index_buffer_offset, entry->index_count);
                }break;

                default:
                {
                    invalid_code_path;
                }
            }
        }

//////// NOTE(gh) Forward rendering start
        // NOTE(gh) draw axis lines
        metal_set_detph_stencil_state(render_encoder, render_context->depth_state);
        metal_set_pipeline(render_encoder, render_context->singlepass_line_pipeline);

        metal_set_vertex_bytes(render_encoder, &per_frame_data, sizeof(per_frame_data), 0);

        f32 x_axis[] = {0.0f, 0.0f, 0.0f, 100.0f, 0.0f, 0.0f};
        v3 x_axis_color = V3(1, 0, 0);
        f32 y_axis[] = {0.0f, 0.0f, 0.0f, 0.0f, 100.0f, 0.0f};
        v3 y_axis_color = V3(0, 1, 0);
        f32 z_axis[] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 100.0f};
        v3 z_axis_color = V3(0, 0, 1);

        // x axis
        metal_set_vertex_bytes(render_encoder, x_axis, sizeof(f32) * array_count(x_axis), 1);
        metal_set_vertex_bytes(render_encoder, &x_axis_color, sizeof(v3), 2);
        metal_draw_non_indexed(render_encoder, MTLPrimitiveTypeLine, 0, 2);

        metal_set_vertex_bytes(render_encoder, y_axis, sizeof(f32) * array_count(y_axis), 1);
        metal_set_vertex_bytes(render_encoder, &y_axis_color, sizeof(v3), 2);
        metal_draw_non_indexed(render_encoder, MTLPrimitiveTypeLine, 0, 2);

        // z axis
        metal_set_vertex_bytes(render_encoder, z_axis, sizeof(f32) * array_count(z_axis), 1);
        metal_set_vertex_bytes(render_encoder, &z_axis_color, sizeof(v3), 2);
        metal_draw_non_indexed(render_encoder, MTLPrimitiveTypeLine, 0, 2);

#if 0
        // NOTE(gh) draw light cube for indication
        m4x4 model = st_m4x4(directional_light_p, V3(0.5f, 0.5f, 0.5f));
        model = transpose(model); // make the matrix column-major
        PerObjectData per_object_data = {};
        per_object_data.model = model;
        per_object_data.color = V3(1, 0, 0);

        metal_set_pipeline(render_encoder, render_context->singlepass_cube_pipeline);
        metal_set_vertex_bytes(render_encoder, &per_object_data, sizeof(per_object_data), 1);
        metal_set_vertex_bytes(render_encoder, cube_vertices, array_size(cube_vertices), 2);
        metal_set_vertex_bytes(render_encoder, cube_normals, sizeof(f32) * array_count(cube_normals), 3);
        metal_set_vertex_bytes(render_encoder, &light_proj_view, sizeof(light_proj_view), 4);

        metal_set_fragment_texture(render_encoder, render_context->directional_light_shadowmap_depth_texture, 0);

        metal_draw_non_indexed(render_encoder, MTLPrimitiveTypeTriangle, 0, array_count(cube_vertices) / 3);
#endif

#if 0
        v3 screen_space_triangle_vertices[] = 
        {
            {-0.7f, -0.7f, 1.0f},
            {0.7f, -0.7f, 1.0f},
            {0.0f, 0.7f, 1.0f},
        };

        metal_set_pipeline(present_render_encoder, render_context->screen_space_triangle_pipeline);
        metal_set_vertex_bytes(present_render_encoder, screen_space_triangle_vertices, array_size(screen_space_triangle_vertices), 0);
        metal_draw_non_indexed(present_render_encoder, MTLPrimitiveTypeTriangle, 0, array_count(screen_space_triangle_vertices));
#endif
        metal_set_viewport(render_encoder, 0, 0, window_width, window_height, 0, 1);
        metal_set_scissor_rect(render_encoder, 0, 0, window_width, window_height);
        metal_set_triangle_fill_mode(render_encoder, MTLTriangleFillModeFill);
        metal_set_front_facing_winding(render_encoder, MTLWindingCounterClockwise);
        metal_set_cull_mode(render_encoder, MTLCullModeBack);
        // NOTE(gh) disable depth testing & writing for deferred lighting
        metal_set_detph_stencil_state(render_encoder, render_context->disabled_depth_state);

        metal_set_pipeline(render_encoder, render_context->singlepass_deferred_lighting_pipeline);

        metal_set_vertex_bytes(render_encoder, &directional_light_p, sizeof(directional_light_p), 0);
        metal_set_vertex_bytes(render_encoder, &render_push_buffer->enable_shadow, sizeof(render_push_buffer->enable_shadow), 1);

        metal_draw_non_indexed(render_encoder, MTLPrimitiveTypeTriangle, 0, 6);

        metal_end_encoding(render_encoder);

        metal_commit_command_buffer(command_buffer);
        // TODO(gh) Double check whether this is syncing correctly...
        metal_wait_until_command_buffer_completed(command_buffer);
    }
}

internal void
metal_display(MetalRenderContext *render_context)
{
    id<MTLCommandBuffer> command_buffer = [render_context->command_queue commandBuffer];

    metal_present_drawable(command_buffer, render_context->view);
    metal_commit_command_buffer(command_buffer);
}
 

// NOTE(gh): returns the base path where all the folders(code, misc, data) are located
internal void
macos_get_base_path(char *dest)
{
    NSString *app_path_string = [[NSBundle mainBundle] bundlePath];
    u32 length = [app_path_string lengthOfBytesUsingEncoding: NSUTF8StringEncoding];
    unsafe_string_append(dest, 
                        [app_path_string cStringUsingEncoding: NSUTF8StringEncoding],
                        length);

    u32 slash_to_delete_count = 2;
    for(u32 index = length-1;
            index >= 0;
            --index)
    {
        if(dest[index] == '/')
        {
            slash_to_delete_count--;
            if(slash_to_delete_count == 0)
            {
                break;
            }
        }
        else
        {
            dest[index] = 0;
        }
    }
}

internal time_t
macos_get_last_modified_time(char *file_name)
{
    time_t result = 0; 

    struct stat file_stat = {};
    stat(file_name, &file_stat); 
    result = file_stat.st_mtime;

    return result;
}

struct MacOSGameCode
{
    void *library;
    time_t last_modified_time; // u32 bit integer
    UpdateAndRender *update_and_render;
};

internal void
macos_load_game_code(MacOSGameCode *game_code, char *file_name)
{
    // NOTE(gh) dlclose does not actually unload the dll!!!
    // dll only gets unloaded if there is no object that is referencing the dll.
    // TODO(gh) library should be remain open? If so, we need another way to 
    // actually unload the dll so that the fresh dll can be loaded.
    if(game_code->library)
    {
        int error = dlclose(game_code->library);
        game_code->update_and_render = 0;
        game_code->last_modified_time = 0;
        game_code->library = 0;
    }

    void *library = dlopen(file_name, RTLD_LAZY|RTLD_GLOBAL);
    if(library)
    {
        game_code->library = library;
        game_code->last_modified_time = macos_get_last_modified_time(file_name);
        game_code->update_and_render = (UpdateAndRender *)dlsym(library, "update_and_render");
    }
}

int main(void)
{ 
    // TODO(gh) studio display only shows half of the pixels(both width and height)?
    CGDirectDisplayID main_displayID = CGMainDisplayID();
    bool is_display_built_in = CGDisplayIsBuiltin(main_displayID);
    size_t display_width = CGDisplayPixelsWide(main_displayID);
    size_t display_height = CGDisplayPixelsHigh(main_displayID);
    CGSize display_dim = CGDisplayScreenSize(main_displayID);
    u32 display_serial_number = CGDisplaySerialNumber(main_displayID);

    char *lock_file_path = "/Volumes/meka/HB_engine/build/PUL.app/Contents/MacOS/lock.tmp";
    char *game_code_path = "/Volumes/meka/HB_engine/build/PUL.app/Contents/MacOS/pul.dylib";
    MacOSGameCode macos_game_code = {};
    macos_load_game_code(&macos_game_code, game_code_path);
 
    u32 random_seed = time(NULL);
    RandomSeries series = start_random_series(random_seed); 

    //TODO : writefile?
    PlatformAPI platform_api = {};
    platform_api.read_file = debug_macos_read_file;
    platform_api.write_entire_file = debug_macos_write_entire_file;
    platform_api.free_file_memory = debug_macos_free_file_memory;

    PlatformMemory platform_memory = {};

    platform_memory.permanent_memory_size = gigabytes(1);
    platform_memory.transient_memory_size = gigabytes(3);
    u64 total_size = platform_memory.permanent_memory_size + platform_memory.transient_memory_size;
    vm_allocate(mach_task_self(), 
                (vm_address_t *)&platform_memory.permanent_memory,
                total_size, 
                VM_FLAGS_ANYWHERE);
    platform_memory.transient_memory = (u8 *)platform_memory.permanent_memory + platform_memory.permanent_memory_size;

    i32 window_width = 1920;
    i32 window_height = 1080;

    u32 target_frames_per_second = 60;
    f32 target_seconds_per_frame = 1.0f/(f32)target_frames_per_second;
    u32 target_nano_seconds_per_frame = (u32)(target_seconds_per_frame*sec_to_nanosec);
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy :NSApplicationActivationPolicyRegular];
    app_delegate *delegate = [app_delegate new];
    [app setDelegate: delegate];

    NSMenu *app_main_menu = [NSMenu alloc];
    NSMenuItem *menu_item_with_item_name = [NSMenuItem new];
    [app_main_menu addItem : menu_item_with_item_name];
    [NSApp setMainMenu:app_main_menu];

    NSMenu *SubMenuOfMenuItemWithAppName = [NSMenu alloc];
    NSMenuItem *quitMenuItem = [[NSMenuItem alloc] initWithTitle:@"Quit" 
                                                    action:@selector(terminate:)  // Decides what will happen when the menu is clicked or selected
                                                    keyEquivalent:@"q"];
    [SubMenuOfMenuItemWithAppName addItem:quitMenuItem];
    [menu_item_with_item_name setSubmenu:SubMenuOfMenuItemWithAppName];

    // TODO(gh): when connected to the external display, this should be window_width and window_height
    // but if not, this should be window_width/2 and window_height/2. Turns out it's based on the resolution(or maybe ppi),
    // because when connected to the apple studio display, the application should use the same value as the macbook monitor
    //NSRect window_rect = NSMakeRect(100.0f, 100.0f, (f32)window_width, (f32)window_height);
    NSRect window_rect = NSMakeRect(100.0f, 100.0f, (f32)window_width/2.0f, (f32)window_height/2.0f);

    NSWindow *window = [[NSWindow alloc] initWithContentRect : window_rect
                                        // Apple window styles : https://developer.apple.com/documentation/appkit/nswindow/stylemask
                                        styleMask : NSTitledWindowMask|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
                                        backing : NSBackingStoreBuffered
                                        defer : NO];

    NSString *app_name = [[NSProcessInfo processInfo] processName];
    [window setTitle:app_name];
    [window makeKeyAndOrderFront:0];
    [window makeKeyWindow];
    [window makeMainWindow];

    char base_path[256] = {};
    macos_get_base_path(base_path);

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSString *name = device.name;
    bool has_unified_memory = device.hasUnifiedMemory;

    // TODO(gh) MTLGPUFamilyApple8 not defined?
    assert(metal_does_support_gpu_family(device, MTLGPUFamilyApple7));

    MTKView *view = [[MTKView alloc] initWithFrame : window_rect
                                        device:device];
    CAMetalLayer *metal_layer = (CAMetalLayer*)[view layer];

    // load vkGetInstanceProcAddr
    //macos_initialize_vulkan(&render_context, metal_layer);

    [window setContentView:view];
    view.depthStencilPixelFormat = MTLPixelFormatDepth32Float;

    MetalRenderContext metal_render_context = {};

    metal_render_context.depth_state = metal_make_depth_state(device, MTLCompareFunctionLess, true);
    metal_render_context.disabled_depth_state = metal_make_depth_state(device, MTLCompareFunctionAlways, false);

    NSError *error;
    // TODO(gh) : Put the metallib file inside the app
    char metallib_path[256] = {};
    unsafe_string_append(metallib_path, base_path);
    unsafe_string_append(metallib_path, "code/shader/shader.metallib");

    // TODO(gh) : maybe just use newDefaultLibrary? If so, figure out where should we put the .metal files
    id<MTLLibrary> shader_library = [device newLibraryWithFile:[NSString stringWithUTF8String:metallib_path] 
                                                                error: &error];
    check_ns_error(error);

    MTLPixelFormat cube_pipeline_color_attachment_pixel_formats[] = {MTLPixelFormatBGRA8Unorm, // placeholder for single pass deferred rendering
                                                                     MTLPixelFormatRGBA32Float, // position
                                                                     MTLPixelFormatRGBA32Float, // normal
                                                                     MTLPixelFormatRGBA8Unorm}; // color
    MTLColorWriteMask cube_pipeline_color_attachment_write_masks[] = {MTLColorWriteMaskNone,
                                                                      MTLColorWriteMaskAll, 
                                                                      MTLColorWriteMaskAll,
                                                                      MTLColorWriteMaskAll};
    metal_render_context.singlepass_cube_pipeline = 
        metal_make_pipeline(device, "Cube Pipeline", 
                            "singlepass_cube_vertex", "singlepass_cube_frag", 
                            shader_library,
                            MTLPrimitiveTopologyClassTriangle,
                            cube_pipeline_color_attachment_pixel_formats, array_count(cube_pipeline_color_attachment_pixel_formats),
                            cube_pipeline_color_attachment_write_masks, array_count(cube_pipeline_color_attachment_write_masks),
                            view.depthStencilPixelFormat);

    MTLPixelFormat deferred_lighting_pipeline_color_attachment_pixel_formats[] = 
        {MTLPixelFormatBGRA8Unorm, // This is the default pixel format for displaying
         MTLPixelFormatRGBA32Float, 
         MTLPixelFormatRGBA32Float,
         MTLPixelFormatRGBA8Unorm};
    MTLColorWriteMask deferred_lighting_pipeline_color_attachment_write_masks[] = 
        {MTLColorWriteMaskAll,
         MTLColorWriteMaskNone,
         MTLColorWriteMaskNone,
         MTLColorWriteMaskNone};
    metal_render_context.singlepass_deferred_lighting_pipeline = 
        metal_make_pipeline(device, "Deferred Lighting Pipeline", 
                            "singlepass_deferred_lighting_vertex", "singlepass_deferred_lighting_frag", 
                            shader_library,
                            MTLPrimitiveTopologyClassTriangle,
                            deferred_lighting_pipeline_color_attachment_pixel_formats, array_count(deferred_lighting_pipeline_color_attachment_pixel_formats),
                            deferred_lighting_pipeline_color_attachment_write_masks, array_count(deferred_lighting_pipeline_color_attachment_write_masks),
                            MTLPixelFormatDepth32Float);

    metal_render_context.directional_light_shadowmap_pipeline = 
        metal_make_pipeline(device, "Directional Light Shadowmap Pipeline", 
                            "directional_light_shadowmap_vert", 0, 
                            shader_library,
                            MTLPrimitiveTopologyClassTriangle,
                            0, 0,
                            0, 0,
                            MTLPixelFormatDepth32Float);


    MTLPixelFormat line_pipeline_color_attachment_pixel_formats[] = {MTLPixelFormatBGRA8Unorm, // This is the default pixel format for displaying
                                                                    MTLPixelFormatRGBA32Float,
                                                                    MTLPixelFormatRGBA32Float,
                                                                    MTLPixelFormatRGBA8Unorm}; 
    MTLColorWriteMask line_pipeline_color_attachment_write_masks[] = {MTLColorWriteMaskAll,
                                                                      MTLColorWriteMaskNone,
                                                                      MTLColorWriteMaskNone,
                                                                      MTLColorWriteMaskNone};
    metal_render_context.singlepass_line_pipeline = 
        metal_make_pipeline(device, "Line Pipeline", 
                            "singlepass_line_vertex", "singlepass_line_frag",
                            shader_library,
                            MTLPrimitiveTopologyClassLine,
                            line_pipeline_color_attachment_pixel_formats, array_count(line_pipeline_color_attachment_pixel_formats),
                            line_pipeline_color_attachment_write_masks, array_count(line_pipeline_color_attachment_write_masks),
                            view.depthStencilPixelFormat);

    MTLPixelFormat screen_space_triangle_pipeline_color_attachment_pixel_formats[] = {MTLPixelFormatBGRA8Unorm}; // This is the default pixel format for displaying
    MTLColorWriteMask screen_space_triangle_pipeline_color_attachment_write_masks[] = {MTLColorWriteMaskAll};
    metal_render_context.screen_space_triangle_pipeline = 
        metal_make_pipeline(device, "Sreen Space Triangle Pipeline", "screen_space_triangle_vert", "screen_space_triangle_frag",
                            shader_library,
                            MTLPrimitiveTopologyClassTriangle,
                            screen_space_triangle_pipeline_color_attachment_pixel_formats, array_count(screen_space_triangle_pipeline_color_attachment_pixel_formats),
                            screen_space_triangle_pipeline_color_attachment_write_masks, array_count(screen_space_triangle_pipeline_color_attachment_write_masks),
                            view.depthStencilPixelFormat);

    id<MTLCommandQueue> command_queue = [device newCommandQueue];

    // NOTE(gh) Create required textures

    // NOTE(gh) For apple silicons, we can use single pass deferred rendering,
    // which requires MTLStorageModeMemoryless(cannot use MTLLoadActionLoad & MTLStoreActionStore))
    metal_render_context.g_buffer_position_texture  = 
        metal_make_texture_2D(device, 
                              MTLPixelFormatRGBA32Float, 
                              window_width, 
                              window_height,
                              MTLTextureType2D,
                              MTLTextureUsageRenderTarget,
                              MTLStorageModeMemoryless);

    metal_render_context.g_buffer_normal_texture  = 
        metal_make_texture_2D(device, 
                              MTLPixelFormatRGBA32Float, 
                              window_width, 
                              window_height,
                              MTLTextureType2D,
                              MTLTextureUsageRenderTarget,
                              MTLStorageModeMemoryless);

    metal_render_context.g_buffer_color_texture  = 
        metal_make_texture_2D(device, 
                              MTLPixelFormatRGBA8Unorm, 
                              window_width, 
                              window_height,
                              MTLTextureType2D,
                              MTLTextureUsageRenderTarget,
                              MTLStorageModeMemoryless);

    metal_render_context.g_buffer_depth_texture  = 
        metal_make_texture_2D(device, 
                              MTLPixelFormatDepth32Float, 
                              window_width, 
                              window_height,
                              MTLTextureType2D,
                              MTLTextureUsageRenderTarget,
                              MTLStorageModeMemoryless);

    // NOTE(gh) Create samplers
    metal_render_context.shadowmap_sampler = 
        metal_make_sampler(device, true, MTLSamplerAddressModeClampToEdge, 
                          MTLSamplerMinMagFilterLinear, MTLSamplerMipFilterNotMipmapped, MTLCompareFunctionLess);

    MTLLoadAction single_lighting_renderpass_color_attachment_load_actions[] = 
        {MTLLoadActionClear,
        MTLLoadActionClear,
        MTLLoadActionClear,
        MTLLoadActionClear};
    MTLStoreAction single_lighting_renderpass_color_attachment_store_actions[] = 
        {MTLStoreActionStore,
        MTLStoreActionDontCare,
        MTLStoreActionDontCare,
        MTLStoreActionDontCare};
    id<MTLTexture> single_lighting_renderpass_color_attachment_textures[] = 
        {0,
        metal_render_context.g_buffer_position_texture,
        metal_render_context.g_buffer_normal_texture,
        metal_render_context.g_buffer_color_texture};
    v4 single_lighting_renderpass_color_attachment_clear_colors[] = 
        {{0, 0, 0, 0},
        {0, 0, 0, 0},
        {0, 0, 0, 0},
        {0, 0, 0, 0}};
    metal_render_context.single_lighting_renderpass = 
        metal_make_renderpass(single_lighting_renderpass_color_attachment_load_actions, array_count(single_lighting_renderpass_color_attachment_load_actions),
                              single_lighting_renderpass_color_attachment_store_actions, array_count(single_lighting_renderpass_color_attachment_store_actions),
                              single_lighting_renderpass_color_attachment_textures, array_count(single_lighting_renderpass_color_attachment_textures),
                              single_lighting_renderpass_color_attachment_clear_colors, array_count(single_lighting_renderpass_color_attachment_clear_colors),
                              MTLLoadActionClear, MTLStoreActionDontCare, 
                              metal_render_context.g_buffer_depth_texture,
                              1.0f);

    // TODO(gh) peter panning happens when the resolution is too low. 
    metal_render_context.directional_light_shadowmap_depth_texture_width = 1024;
    metal_render_context.directional_light_shadowmap_depth_texture_height = 1024;
    metal_render_context.directional_light_shadowmap_depth_texture = 
        metal_make_texture_2D(device, 
                              MTLPixelFormatDepth32Float, 
                              metal_render_context.directional_light_shadowmap_depth_texture_width, 
                              metal_render_context.directional_light_shadowmap_depth_texture_height,
                              MTLTextureType2D,
                              MTLTextureUsageRenderTarget,
                              MTLStorageModePrivate);
    metal_render_context.directional_light_shadowmap_renderpass = 
        metal_make_renderpass(0, 0,
                              0, 0,
                              0, 0, 
                              0, 0,
                              MTLLoadActionClear, MTLStoreActionStore,
                              metal_render_context.directional_light_shadowmap_depth_texture,
                              1.0f);
    
    metal_render_context.combined_vertex_buffer = metal_make_managed_buffer(device, gigabytes(1));
    metal_render_context.combined_index_buffer = metal_make_managed_buffer(device, megabytes(256));

    metal_render_context.device = device;
    metal_render_context.view = view;
    metal_render_context.command_queue = command_queue;

    // TODO(gh) More robust way to manage these buffers??(i.e asset system?)

    CVDisplayLinkRef display_link;
    if(CVDisplayLinkCreateWithActiveCGDisplays(&display_link) == kCVReturnSuccess)
    {
        CVDisplayLinkSetOutputCallback(display_link, display_link_callback, 0); 
        CVDisplayLinkStart(display_link);

        if(CVDisplayLinkSetCurrentCGDisplay(display_link, main_displayID) == kCVReturnSuccess)
        {
            // TODO(gh) Now we set the display link with the display,
            // the OS will call display link callback function periodically when it wants to display something.
            // Sync this with our display function.
        }
        else
        {
            // TODO(gh) log
            printf("Failed to set the display link with main display\n");
            invalid_code_path;
        }
    }
    else
    {
        // TODO(gh) log
        printf("Failed to create compatible display link with the displays\n");
        invalid_code_path;
    }

    PlatformInput platform_input = {};

    PlatformRenderPushBuffer platform_render_push_buffer = {};
    platform_render_push_buffer.total_size = megabytes(16);
    platform_render_push_buffer.base = (u8 *)malloc(platform_render_push_buffer.total_size);
    // TODO(gh) Make sure to update this value whenever we resize the window
    platform_render_push_buffer.width_over_height = (f32)window_width / (f32)window_height;

    platform_render_push_buffer.combined_vertex_buffer = metal_render_context.combined_vertex_buffer.memory;
    platform_render_push_buffer.vertex_buffer_size = metal_render_context.combined_vertex_buffer.size;
    platform_render_push_buffer.combined_index_buffer = metal_render_context.combined_index_buffer.memory;
    platform_render_push_buffer.index_buffer_size = metal_render_context.combined_index_buffer.size;

    [app activateIgnoringOtherApps:YES];
    [app run];

    u64 last_time = mach_absolute_time();
    is_game_running = true;
    while(is_game_running)
    {
        platform_input.dt_per_frame = target_seconds_per_frame;
        macos_handle_event(app, window, &platform_input);

        // TODO(gh): check if the focued window is working properly
        b32 is_window_focused = [app keyWindow] && [app mainWindow];

        /*
            TODO(gh) : For more precisely timed rendering, the operations should be done in this order
            1. Update the game based on the input
            2. Check the mach absolute time
            3. With the return value from the displayLinkOutputCallback function, get the absolute time to present
            4. Use presentDrawable:atTime to present at the specific time
        */

        // TODO(gh) : last permission bit should not matter, but double_check?
        int lock_file = open(lock_file_path, O_RDONLY); 
        if(lock_file < 0)
        {
            if(macos_get_last_modified_time(game_code_path) != macos_game_code.last_modified_time)
            {
                macos_load_game_code(&macos_game_code, game_code_path);
            }
        }
        else
        {
            close(lock_file);
        }

        if(macos_game_code.update_and_render)
        {
            macos_game_code.update_and_render(&platform_api, &platform_input, &platform_memory, &platform_render_push_buffer);
        }

        @autoreleasepool
        {
            metal_render_and_wait_until_completion(&metal_render_context, &platform_render_push_buffer, window_width, window_height, target_seconds_per_frame);

            u64 time_passed_in_nsec = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - last_time;
            u32 time_passed_in_msec = (u32)(time_passed_in_nsec / sec_to_millisec);
            f32 time_passed_in_sec = (f32)time_passed_in_nsec / sec_to_nanosec;
            if(time_passed_in_nsec < target_nano_seconds_per_frame)
            {
                // NOTE(gh): Because nanosleep is such a high resolution sleep method, for precise timing,
                // we need to undersleep and spend time in a loop
                u64 undersleep_nano_seconds = target_nano_seconds_per_frame / 10;
                if(time_passed_in_nsec + undersleep_nano_seconds < target_nano_seconds_per_frame)
                {
                    timespec time_spec = {};
                    time_spec.tv_nsec = target_nano_seconds_per_frame - time_passed_in_nsec -  undersleep_nano_seconds;

                    nanosleep(&time_spec, 0);
                }

                // For a short period of time, loop
                time_passed_in_nsec = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - last_time;
                while(time_passed_in_nsec < target_nano_seconds_per_frame)
                {
                    time_passed_in_nsec = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - last_time;
                }
                time_passed_in_msec = (u32)(time_passed_in_nsec / sec_to_millisec);
                time_passed_in_sec = (f32)time_passed_in_nsec / sec_to_nanosec;
            }
            else
            {
                // TODO : Missed Frame!
                // TODO(gh) : Whenever we miss the frame re-sync with the display link
                printf("Missed frame, exceeded by %dms(%.6fs)!\n", time_passed_in_msec, time_passed_in_sec);
            }

            printf("%dms elapsed, fps : %.6f\n", time_passed_in_msec, 1.0f/time_passed_in_sec);

            metal_display(&metal_render_context);
        }

#if 0
        // NOTE(gh) : debug_printf_all_cycle_counters
        for(u32 cycle_counter_index = 0;
                cycle_counter_index < debug_cycle_counter_count;
                cycle_counter_index++)
        {
            printf("ID:%u  Total Cycles: %llu Hit Count: %u, CyclesPerHit: %u\n", cycle_counter_index, 
                                                                             debug_cycle_counters[cycle_counter_index].cycle_count,
                                                                            debug_cycle_counters[cycle_counter_index].hit_count, 
                                                                            (u32)(debug_cycle_counters[cycle_counter_index].cycle_count/debug_cycle_counters[cycle_counter_index].hit_count));
        }
#endif

        // update the time stamp
        last_time = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    }

    return 0;
}











