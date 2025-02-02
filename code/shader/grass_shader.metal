/*
 * Written by Gyuhyun Lee
 */

#include "shader_common.h"

uint wang_hash(uint seed)
{
    seed = (seed ^ 61) ^ (seed >> 16);
    seed *= 9;
    seed = seed ^ (seed >> 4);
    seed *= 0x27d4eb2d;
    seed = seed ^ (seed >> 15);
    return seed;
}

// From one the the Apple's sample shader codes - 
// https://developer.apple.com/library/archive/samplecode/MetalShaderShowcase/Listings/MetalShaderShowcase_AAPLWoodShader_metal.html
float random_between_0_1(int x, int y, int z)
{
    int seed = x + y * 57 + z * 241;
    seed = (seed << 13) ^ seed;
    return (( 1.0 - ( (seed * (seed * seed * 15731 + 789221) + 1376312589) & 2147483647) / 1073741824.0f) + 1.0f) / 2.0f;
}

bool
is_inside_cube(packed_float3 p, packed_float3 min, packed_float3 max)
{
    bool result = true;
    if(p.x < min.x || p.x > max.x ||
        p.y < min.y || p.y > max.y ||    
        p.z < min.z || p.z > max.z)
    {
        result = false;
    }

    return result;
}

// TODO(gh) Should be more conservative with the value,
// and also change this to seperating axis test 
bool 
is_inside_frustum(constant float4x4 *proj_view, float3 min, float3 max)
{
    bool result = false;

    float4 vertices[8] = 
    {
        // bottom
        float4(min.x, min.y, min.z, 1.0f),
        float4(min.x, max.y, min.z, 1.0f),
        float4(max.x, min.y, min.z, 1.0f),
        float4(max.x, max.y, min.z, 1.0f),

        // top
        float4(min.x, min.y, max.z, 1.0f),
        float4(min.x, max.y, max.z, 1.0f),
        float4(max.x, min.y, max.z, 1.0f),
        float4(max.x, max.y, max.z, 1.0f),
    };

    for(uint i = 0;
            i < 8 && !result;
            ++i)
    {
        // homogeneous p
        float4 hp = (*proj_view) * vertices[i];

        // We are using projection matrix which puts z to 0 to 1
        if((hp.x >= -hp.w && hp.x <= hp.w) &&
            (hp.y >= -hp.w && hp.y <= hp.w) &&
            (hp.z >= 0 && hp.z <= hp.w))
        {
            result = true;
            break;
        }
    }

    return result;
}
 
struct MACID
{
    // ID0 is smaller than ID1, no matter what axis that it's opertating on
    int ID0;
    int ID1;
};

// TODO(gh) Should double-check these functions
static MACID
get_mac_index_x(int x, int y, int z, packed_int3 cell_count)
{
    MACID result = {};
    result.ID0 = cell_count.y*(cell_count.x+1)*z + (cell_count.x+1)*y + x;
    result.ID1 = result.ID0+1;
    return result;
}

static float
get_mac_center_value_x(device float *x, int cell_x, int cell_y, int cell_z, constant packed_int3 *cell_count)
{
    MACID macID = get_mac_index_x(cell_x, cell_y, cell_z, *cell_count);

    float result = 0.5f*(x[macID.ID0] + x[macID.ID1]);

    return result;
}

static MACID
get_mac_index_y(int x, int y, int z, packed_int3 cell_count)
{
    MACID result = {};
    result.ID0 = cell_count.x*(cell_count.y+1)*z + (cell_count.y+1)*x + y;
    result.ID1 = result.ID0+1;
    return result;
}

static float
get_mac_center_value_y(device float *y, int cell_x, int cell_y, int cell_z, constant packed_int3 *cell_count)
{
    MACID macID = get_mac_index_y(cell_x, cell_y, cell_z, *cell_count);

    float result = 0.5f*(y[macID.ID0] + y[macID.ID1]);

    return result;
}

static MACID
get_mac_index_z(int x, int y, int z, packed_int3 cell_count)
{
    MACID result = {};
    result.ID0 = cell_count.x*(cell_count.z+1)*y + (cell_count.z+1)*x + z;
    result.ID1 = result.ID0+1;
    return result;
}

static float
get_mac_center_value_z(device float *z, int cell_x, int cell_y, int cell_z, constant packed_int3 *cell_count)
{
    MACID macID = get_mac_index_z(cell_x, cell_y, cell_z, *cell_count);

    float result = 0.5f*(z[macID.ID0] + z[macID.ID1]);

    return result;
}

static int
get_mac_index_center(int x, int y, int z, packed_int3 cell_count)
{
    int result = cell_count.x*cell_count.y*z + cell_count.x*y + x;
    return result;
}


static packed_float3
get_mac_bilinear_center_value(device float *x, device float *y, device float *z, packed_float3 p, 
                                constant packed_int3 *cell_count)
{
    packed_float3 result;

    p.x = clamp(p.x, 0.5f, cell_count->x-0.5f);
    p.y = clamp(p.y, 0.5f, cell_count->y-0.5f);
    p.z = clamp(p.z, 0.5f, cell_count->z-0.5f);

    p -= packed_float3(0.5f, 0.5f, 0.5f);

    // TODO(gh) This might produce slightly wrong value?
    int x0 = floor(p.x);
    int x1 = x0 + 1;
    if(x1 == cell_count->x)
    {
        x0--;
        x1--;
    }
    float xf = p.x-x0;

    int y0 = floor(p.y);
    int y1 = y0 + 1;
    if(y1 == cell_count->y)
    {
        y0--;
        y1--;
    }
    float yf = p.y-y0;

    int z0 = floor(p.z);
    int z1 = z0 + 1;
    if(z1 == cell_count->z)
    {
        z0--;
        z1--;
    }
    float zf = p.z - z0;

    result.x =
            lerp(
                lerp(lerp(get_mac_center_value_x(x, x0, y0, z0, cell_count), xf, get_mac_center_value_x(x, x1, y0, z0, cell_count)), 
                    yf, 
                    lerp(get_mac_center_value_x(x, x0, y1, z0, cell_count), xf, get_mac_center_value_x(x, x1, y1, z0, cell_count))),
                zf,
                lerp(lerp(get_mac_center_value_x(x, x0, y0, z1, cell_count), xf, get_mac_center_value_x(x, x1, y0, z1, cell_count)), 
                    yf, 
                    lerp(get_mac_center_value_x(x, x0, y1, z1, cell_count), xf, get_mac_center_value_x(x, x1, y1, z1, cell_count))));

    result.y = 
            lerp(
                lerp(lerp(get_mac_center_value_y(y, x0, y0, z0, cell_count), xf, get_mac_center_value_y(y, x1, y0, z0, cell_count)), 
                    yf, 
                    lerp(get_mac_center_value_y(y, x0, y1, z0, cell_count), xf, get_mac_center_value_y(y, x1, y1, z0, cell_count))),
                zf,
                lerp(lerp(get_mac_center_value_y(y, x0, y0, z1, cell_count), xf, get_mac_center_value_y(y, x1, y0, z1, cell_count)), 
                    yf, 
                    lerp(get_mac_center_value_y(y, x0, y1, z1, cell_count), xf, get_mac_center_value_y(y, x1, y1, z1, cell_count))));

    result.z = 
            lerp(
                lerp(lerp(get_mac_center_value_z(z, x0, y0, z0, cell_count), xf, get_mac_center_value_z(z, x1, y0, z0, cell_count)), 
                    yf, 
                    lerp(get_mac_center_value_z(z, x0, y1, z0, cell_count), xf, get_mac_center_value_z(z, x1, y1, z0, cell_count))),
                zf,
                lerp(lerp(get_mac_center_value_z(z, x0, y0, z1, cell_count), xf, get_mac_center_value_z(z, x1, y0, z1, cell_count)), 
                    yf, 
                    lerp(get_mac_center_value_z(z, x0, y1, z1, cell_count), xf, get_mac_center_value_z(z, x1, y1, z1, cell_count))));
    return result;
}

#define target_seconds_per_frame (1/60.0f)

// NOTE(gh) p0 is on the ground and does not move
static void
offset_control_points_with_dynamic_wind(device packed_float3 *p0, device packed_float3 *p1, device packed_float3 *p2, 
                                        float original_p0_p1_length, float original_p0_p2_length,
                                         packed_float3 wind, float dt, float noise)
{
    // TODO(gh) We can re-adjust p2 after adjusting p1
    float one_minus_noise = noise;
    packed_float3 p0_p1 = normalize(*p1 + dt*one_minus_noise*wind - *p0);
    *p1 = *p0 + original_p0_p1_length*p0_p1;

    packed_float3 p0_p2 = normalize(*p2 + dt*one_minus_noise*wind - *p0);
    *p2 = *p0 + original_p0_p2_length*p0_p2;

}

static void
offset_control_points_with_spring(thread packed_float3 *original_p1, thread packed_float3 *original_p2,
                                   device packed_float3 *p1, device packed_float3 *p2, float spring_c, float noise, float dt)
{
    float p2_spring_c = spring_c/2.f;

    // NOTE(gh) Reversing the wind noise(and offsetting by some amount) 
    // to improve grass bobbing
    float one_minus_noise = (1.0f - noise - 0.3f);
    *p1 += dt*one_minus_noise*spring_c*(powr(2, length(*original_p1 - *p1))-1)*normalize(*original_p1 - *p1);
    *p2 += dt*one_minus_noise*p2_spring_c*(powr(2, length(*original_p2 - *p2))-1)*normalize(*original_p2 - *p2);
}

kernel void
initialize_grass_grid(device GrassInstanceData *grass_instance_buffer [[buffer(0)]],
                                const device float *floor_z_values [[buffer (1)]],
                                constant GridInfo *grid_info [[buffer (2)]],
                                constant packed_float3 *wind_noise_texture_world_dim [[buffer (3)]],
                                uint2 thread_count_per_grid [[threads_per_grid]],
                                uint2 thread_position_in_grid [[thread_position_in_grid]])
{
    uint grass_index = thread_count_per_grid.x*thread_position_in_grid.y + thread_position_in_grid.x;
    float z = floor_z_values[grass_index];
    float3 p0 = packed_float3(grid_info->min, 0) + 
                    packed_float3(grid_info->one_thread_worth_dim.x*thread_position_in_grid.x, 
                                  grid_info->one_thread_worth_dim.y*thread_position_in_grid.y, 
                                  z);
    
    uint hash = 10000*(wang_hash(grass_index)/(float)0xffffffff);
    float random01 = (float)hash/(float)(10000);
    float length = 2.8h + random01;
    float tilt = clamp(1.9f + 0.7f*random01, 0.0f, length - 0.01f);

    float2 facing_direction = float2(cos((float)hash), sin((float)hash));
    float stride = sqrt(length*length - tilt*tilt); // only horizontal length of the blade
    float bend = 0.6f + 0.2f*random01;

    float3 original_p2 = p0 + stride * float3(facing_direction, 0.0f) + float3(0, 0, tilt);  
    float3 orthogonal_normal = normalize(float3(-facing_direction.y, facing_direction.x, 0.0f)); // Direction of the width of the grass blade, think it should be (y, -x)?
    float3 blade_normal = normalize(cross(original_p2 - p0, orthogonal_normal)); // normal of the p0 and p2, will be used to get p1 
    float3 original_p1 = p0 + (2.0f/4.0f) * (original_p2 - p0) + bend * blade_normal;

    grass_instance_buffer[grass_index].p0 = packed_float3(p0);
    grass_instance_buffer[grass_index].p1 = packed_float3(original_p1);
    grass_instance_buffer[grass_index].p2 = packed_float3(original_p2);

    grass_instance_buffer[grass_index].orthogonal_normal = packed_float3(orthogonal_normal);
    grass_instance_buffer[grass_index].hash = hash; 
    grass_instance_buffer[grass_index].blade_width = 0.165f;
    grass_instance_buffer[grass_index].spring_c = 4.5f + 4*random01;
    grass_instance_buffer[grass_index].color = packed_float3(random01, 0.784h, 0.2h);
    grass_instance_buffer[grass_index].texture_p = p0;
}

kernel void
fill_grass_instance_data_compute(device atomic_uint *grass_count [[buffer(0)]],
                                device GrassInstanceData *grass_instance_buffer [[buffer(1)]],
                                const device GridInfo *grid_info [[buffer (2)]],
                                constant float4x4 *game_proj_view [[buffer (3)]],
                                device float *fluid_cube_v_x [[buffer (4)]],
                                device float *fluid_cube_v_y [[buffer (5)]],
                                device float *fluid_cube_v_z [[buffer (6)]],
                                constant packed_float3 *fluid_cube_min [[buffer (7)]],
                                constant packed_float3 *fluid_cube_max [[buffer (8)]],
                                constant packed_int3 *fluid_cube_cell_count [[buffer (9)]],
                                constant float *fluid_cube_cell_dim [[buffer (10)]],
                                texture3d<float> wind_noise_texture [[texture(0)]],
                                uint2 thread_count_per_grid [[threads_per_grid]],
                                uint2 thread_position_in_grid [[thread_position_in_grid]])
{
    uint grass_index = thread_count_per_grid.x*thread_position_in_grid.y + thread_position_in_grid.x;
    packed_float3 p0 = grass_instance_buffer[grass_index].p0;
    
    // TODO(gh) better hash function for each grass?
    uint hash = 10000*(wang_hash(grass_index)/(float)0xffffffff);
    float random01 = (float)hash/(float)(10000);
    float grass_length = 2.8h + random01;
    float tilt = clamp(1.9f + 0.7f*random01, 0.0f, grass_length - 0.01f);

#if 0
    // TODO(gh) This does not take account of side curve of the plane, tilt ... so many things
    // Also, we can make the length smaller based on the facing direction
    // These pad values are not well thought out, just throwing those in
    float3 length_pad = 0.6f*float3(length, length, 0.0f);
    float3 min = p0 - length_pad;
    float3 max = p0 + length_pad;
    max.z += tilt + 1.0f;
     
    // TODO(gh) For now, we should disable this and rely on grid based frustum culling
    // because we need to know the previous instance data in certain position
    // which means the instance buffer cannot be mixed up. The solution for this would be some sort of hash table,
    // but we should measure them and see which way would be faster.
    if(is_inside_frustum(game_proj_view, min, max))
#endif
    {
        atomic_fetch_add_explicit(grass_count, 1, memory_order_relaxed);

        // TODO(gh) Pass this value
        packed_float3 wind_v = packed_float3(3, 0, 0);
        if(is_inside_cube(p0, *fluid_cube_min, *fluid_cube_max))
        {
            packed_float3 cell_p = (p0 - *fluid_cube_min) / *fluid_cube_cell_dim;

#if 0
            wind_v += get_mac_bilinear_center_value(fluid_cube_v_x, fluid_cube_v_y, fluid_cube_v_z, cell_p, fluid_cube_cell_count);
#else
            int xi = floor(cell_p.x);
            int yi = floor(cell_p.y);
            int zi = floor(cell_p.z);
            wind_v += packed_float3(get_mac_center_value_x(fluid_cube_v_x, xi, yi, zi, fluid_cube_cell_count),
                    get_mac_center_value_y(fluid_cube_v_y, xi, yi, zi, fluid_cube_cell_count),
                    get_mac_center_value_z(fluid_cube_v_z, xi, yi, zi, fluid_cube_cell_count));
#endif
        }

        constexpr sampler s = sampler(coord::normalized, address::repeat, filter::linear);

        // TODO(gh) Should make this right! I guess this is the 'scale' that god of war used?
        float3 texcoord = grass_instance_buffer[grass_index].texture_p/(*fluid_cube_cell_dim);
        float wind_noise = wind_noise_texture.sample(s, texcoord).x;

        float2 facing_direction = float2(cos((float)hash), sin((float)hash));
        float stride = sqrt(grass_length*grass_length - tilt*tilt); // only horizontal length of the blade
        float bend = 0.7f + 0.2f*random01;

        packed_float3 original_p2 = p0 + stride * float3(facing_direction, 0.0f) + float3(0, 0, tilt);  
        // Direction of the width of the grass blade, think it should be (y, -x)?
        packed_float3 orthogonal_normal = normalize(float3(-facing_direction.y, facing_direction.x, 0.0f)); 
        packed_float3 blade_normal = normalize(cross(original_p2 - p0, orthogonal_normal)); // normal of the p0 and p2, will be used to get p1 
        packed_float3 original_p1 = p0 + (2.5f/4.0f) * (original_p2 - p0) + bend * blade_normal;

        float original_p0_p1_length = length(original_p1 - p0);
        float original_p0_p2_length = length(original_p2 - p0);

        offset_control_points_with_dynamic_wind(&grass_instance_buffer[grass_index].p0, 
                                                    &grass_instance_buffer[grass_index].p1,
                                                    &grass_instance_buffer[grass_index].p2, 
                                                    original_p0_p1_length, original_p0_p2_length,
                                                    wind_v, target_seconds_per_frame, 
                                                    wind_noise);

        offset_control_points_with_spring(&original_p1, &original_p2,
                                            &grass_instance_buffer[grass_index].p1,
                                            &grass_instance_buffer[grass_index].p2, grass_instance_buffer[grass_index].spring_c, wind_noise, target_seconds_per_frame);

        // grass_instance_buffer[grass_index].orthogonal_normal = normalize(cross(packed_float3(0, 0, 1), grass_instance_buffer[grass_index].p2 - grass_instance_buffer[grass_index].p1));

        grass_instance_buffer[grass_index].texture_p -= target_seconds_per_frame*wind_noise*wind_v;
    }
}

struct Arguments 
{
    // TODO(gh) not sure what this is.. but it needs to match with the index of newArgumentEncoderWithBufferIndex
    command_buffer cmd_buffer [[id(0)]]; 
};

// TODO(gh) Use two different vertex functions to support distance-based LOD
kernel void 
encode_instanced_grass_render_commands(device Arguments *arguments[[buffer(0)]],
                                            const device uint *grass_count [[buffer(1)]],
                                            const device GrassInstanceData *grass_instance_buffer [[buffer(2)]],
                                            const device uint *indices [[buffer(3)]],
                                            constant float4x4 *render_proj_view [[buffer(4)]],
                                            constant float4x4 *light_proj_view [[buffer(5)]],
                                            constant packed_float3 *game_camera_p [[buffer(6)]])
{
    render_command command(arguments->cmd_buffer, 0);

    command.set_vertex_buffer(grass_instance_buffer, 0);
    command.set_vertex_buffer(render_proj_view, 1);
    command.set_vertex_buffer(light_proj_view, 2);
    command.set_vertex_buffer(game_camera_p, 3);

    command.draw_indexed_primitives(primitive_type::triangle, // primitive type
                                    39, // index count TODO(gh) We can also just pass those in, too?
                                    indices, // index buffer
                                    *grass_count, // instance count
                                    0, // base vertex
                                    0); //base instance

}


// NOTE(gh) simplifed form of (1-t)*{(1-t)*p0+t*p1} + t*{(1-t)*p1+t*p2}
float3
quadratic_bezier(float3 p0, float3 p1, float3 p2, float t)
{
    float one_minus_t = 1-t;

    return one_minus_t*one_minus_t*p0 + 2*t*one_minus_t*p1 + t*t*p2;
}

// NOTE(gh) first derivative = 2*(1-t)*(p1-p0) + 2*t*(p2-p1)
float3
quadratic_bezier_first_derivative(float3 p0, float3 p1, float3 p2, float t)
{
    float3 result = 2*(1-t)*(p1-p0) + 2*t*(p2-p1);

    return result;
}

GBufferVertexOutput
calculate_grass_vertex(const device GrassInstanceData *grass_instance_data, 
                        uint thread_index, 
                        constant float4x4 *proj_view,
                        constant float4x4 *light_proj_view,
                        constant packed_float3 *camera_p,
                        uint grass_vertex_count,
                        uint grass_divide_count)
{
    half blade_width = grass_instance_data->blade_width;

    const packed_float3 p0 = grass_instance_data->p0;
    const packed_float3 p1 = grass_instance_data->p1;
    const packed_float3 p2 = grass_instance_data->p2;
    const packed_float3 orthogonal_normal = grass_instance_data->orthogonal_normal;

    float t = (float)(thread_index / 2) / (float)grass_divide_count;

    float3 world_p = quadratic_bezier(p0, p1, p2, t);

    if(thread_index == grass_vertex_count-1)
    {
        world_p += 0.5f * blade_width * orthogonal_normal;
    }
    else
    {
        // TODO(gh) Clean this up! 
        // TODO(gh) Original method do it in view angle, any reason to do that
        // (grass possibly facing the direction other than z)?
        bool should_shift_thread_mod_1 = (dot(orthogonal_normal, *camera_p - p0) < 0);
        float shift = 0.08f;
        if(thread_index%2 == 1)
        {
            world_p += blade_width * orthogonal_normal;
            if(should_shift_thread_mod_1 && thread_index != 1)
            {
                world_p.z += shift;
            }
        }
        else
        {
            if(!should_shift_thread_mod_1 && thread_index != 0)
            {
                world_p.z += shift;
            }
        }
    }


    GBufferVertexOutput result;
    result.clip_p = (*proj_view) * float4(world_p, 1.0f);
    result.p = world_p;
    result.N = normalize(cross(quadratic_bezier_first_derivative(p0, p1, p2, t), orthogonal_normal));
    // TODO(gh) Also make this as a half?
    result.color = packed_float3(grass_instance_data->color);
    result.depth = result.clip_p.z / result.clip_p.w;
    float4 p_in_light_coordinate = (*light_proj_view) * float4(world_p, 1.0f);
    result.p_in_light_coordinate = p_in_light_coordinate.xyz / p_in_light_coordinate.w;

    return result;
}


kernel void
initialize_grass_counts(device atomic_uint *grass_count [[buffer(0)]])
{
    atomic_exchange_explicit(grass_count, 0, memory_order_relaxed);
}


vertex GBufferVertexOutput
grass_indirect_render_vertex(uint vertexID [[vertex_id]],
                            uint instanceID [[instance_id]],
                            const device GrassInstanceData *grass_instance_buffer [[buffer(0)]],
                            constant float4x4 *render_proj_view [[buffer(1)]],
                            constant float4x4 *light_proj_view [[buffer(2)]],
                            constant packed_float3 *game_camera_p [[buffer(3)]])
                                            
{
    GBufferVertexOutput result = calculate_grass_vertex(grass_instance_buffer + instanceID, 
                                                        vertexID, 
                                                        render_proj_view,
                                                        light_proj_view,
                                                        game_camera_p,
                                                        grass_high_lod_vertex_count,
                                                        grass_high_lod_divide_count);
    
    return result;
}

/*
   NOTE(gh) This fragment shader is pretty much identical(for now) to 
   the one that we were using for other objects, but this one doens't use shadowmap
   as there is no way to pass texture & sampler to the fragment shader using icb
*/
fragment GBuffers 
grass_indirect_render_fragment(GBufferVertexOutput vertex_output [[stage_in]])

{
    GBuffers result = {};

    result.position = float4(vertex_output.p, 0.0f);
    result.normal = float4(vertex_output.N, 1.0f); // also storing the shadow factor to the unused 4th component
    result.color = float4(vertex_output.color, 1.0f);
   
    return result;
}




