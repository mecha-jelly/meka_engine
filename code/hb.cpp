/*
 * Written by Gyuhyun Lee
 */
#include "hb_types.h"
#include "hb_simd.h"
#include "hb_intrinsic.h"
#include "hb_math.h"
#include "hb_random.h"
#include "hb_font.h"
#include "hb_shared_with_shader.h"
#include "hb_render.h"
#include "hb_pbd.h"
#include "hb_entity.h"
#include "hb_fluid.h"
#include "hb_asset.h"
#include "hb_platform.h"
#include "hb_debug.h"
#include "hb.h"

#include "hb_ray.cpp"
#include "hb_noise.cpp"
#include "hb_mesh_generation.cpp"
#include "hb_pbd.cpp"
#include "hb_entity.cpp"
#include "hb_asset.cpp"
#include "hb_render.cpp"
#include "hb_image_loader.cpp"
#include "hb_fluid.cpp"
#include "hb_obj.cpp"

// TODO(gh) not a great idea
#include <time.h>

internal void 
output_debug_records(PlatformRenderPushBuffer *platform_render_push_buffer, GameAssets *assets, v2 p);

/*
   TODO(gh)
   - Render Font using one of the graphics API
   - If we are going to use the packed texture, how should we correctly sample from it in the shader?
   */

extern "C" 
GAME_UPDATE_AND_RENDER(update_and_render)
{
    GameState *game_state = (GameState *)platform_memory->permanent_memory;
    if(!game_state->is_initialized)
    {
        assert(platform_render_push_buffer->transient_buffer);

        game_state->transient_arena = start_memory_arena(platform_memory->transient_memory, megabytes(512));

        game_state->max_entity_count = 8192;
        game_state->entities = push_array(&game_state->transient_arena, Entity, game_state->max_entity_count);

        // NOTE(gh) Initialize the arenas
        game_state->render_arena = start_memory_arena((u8 *)platform_memory->transient_memory + 
                game_state->transient_arena.total_size + 
                game_state->mass_agg_arena.total_size,
                megabytes(16));
        MemoryArena pbd_arena = start_sub_arena(&game_state->transient_arena, megabytes(4));

        game_state->game_camera = init_fps_camera(V3(0, -10, 22), 1.0f, 135, 1.0f, 1000.0f);
        game_state->debug_camera = init_fps_camera(V3(0, 0, 22), 1.0f, 135, 0.1f, 10000.0f);
        // Close camera
        // game_state->circle_camera = init_circle_camera(V3(0, 0, 5), V3(), 5.0f, 135, 0.01f, 10000.0f);
        // Far away camera
        game_state->circle_camera = init_circle_camera(V3(0, 0, 20), V3(), 20.0f, 135, 0.01f, 10000.0f);
        // Really far away camera
        // game_state->circle_camera = init_circle_camera(V3(0, 0, 50), V3(), 50.0f, 135, 0.01f, 10000.0f);

        load_game_assets(&game_state->assets, &game_state->transient_arena, platform_api, gpu_work_queue);
        PlatformReadFileResult bunny_file = platform_api->read_file("/Volumes/meka/HB_engine/data/teapot.obj");
        PreParseObjResult bunny_pre_parse_result = pre_parse_obj(bunny_file.memory, bunny_file.size);
        v3 *positions = push_array(&game_state->transient_arena, v3, bunny_pre_parse_result.position_count);
        u32 *indices = push_array(&game_state->transient_arena, u32, bunny_pre_parse_result.index_count);
        parse_obj(&bunny_pre_parse_result, bunny_file.memory, bunny_file.size, 
                    positions, 0, 0, indices);

#if 0
        VertexPN *vertices = push_array(&game_state->transient_arena, VertexPN, bunny_pre_parse_result.position_count);
        for(u32 vertex_index = 0;
                vertex_index < bunny_pre_parse_result.position_count;
                ++vertex_index)
        {
            vertices[vertex_index].p = positions[vertex_index];
            vertices[vertex_index].n = V3();
        }

        add_pbd_mesh_entity(game_state, 
                            &pbd_arena, &game_state->transient_arena, 
                            positions, bunny_pre_parse_result.position_count,
                            0.0006f, 1/10.0f, V3(0.7f, 0.2f, 0), EntityFlag_Movable|EntityFlag_Collides);
#endif
#if 0
        load_mesh_asset(GameAssets *assets, ThreadWorkQueue *gpu_work_queue, 
                        AssetTag_BunnyMesh, 
                        vertices, bunny_pre_parse_result.position_count,
                        u32 *indices, bunny_pre_parse_result.index_count);
#endif
#if 0
        v2 grid_dim = V2(80, 80); // TODO(gh) just temporary, need to 'gather' the floors later
        game_state->grass_grid_count_x = 2;
        game_state->grass_grid_count_y = 2;
        game_state->grass_grids = push_array(&game_state->transient_arena, GrassGrid, game_state->grass_grid_count_x*game_state->grass_grid_count_y);

        // TODO(gh) Beware that when you change this value, you also need to change the size of grass instance buffer
        // and the indirect command count(for now)
        u32 grass_per_grid_count_x = 256;
        u32 grass_per_grid_count_y = 256;

        // u32 grass_per_grid_count_x = 64;
        // u32 grass_per_grid_count_y = 64;

        v2 floor_left_bottom_p = hadamard(-V2(game_state->grass_grid_count_x/2, game_state->grass_grid_count_y/2), grid_dim);
        for(u32 y = 0;
                y < game_state->grass_grid_count_y;
                ++y)
        {
            for(u32 x = 0;
                    x < game_state->grass_grid_count_x;
                    ++x)
            {
                v2 min = floor_left_bottom_p + hadamard(grid_dim, V2(x, y));
                v2 max = min + grid_dim;
                v3 center = V3(0.5f*(min + max), 0);

                Entity *floor_entity = 
                    add_floor_entity(game_state, &game_state->transient_arena, center, grid_dim, V3(0.25f, 0.1f, 0.04f), grass_per_grid_count_x, grass_per_grid_count_y, 16);

                GrassGrid *grid = game_state->grass_grids + y*game_state->grass_grid_count_x + x;
                init_grass_grid(thread_work_queue, gpu_work_queue, &game_state->transient_arena, floor_entity, grid, grass_per_grid_count_x, grass_per_grid_count_y, min, max);
            }
        }
#endif

        add_floor_entity(game_state, &game_state->transient_arena, V3(), V2(100, 100), V3(1.0f, 1.0f, 1.0f), 1, 1, 0);


#if 1
        add_pbd_soft_body_tetrahedron_entity(game_state, &pbd_arena, 
                                             V3(0, 2, 14),
                                             V3(-4, 0, 5), V3(4, 0, 12), V3(0, 4, 8),
                                             0.0f, 1/10.0f, V3(0, 0.8f, 0.2f), EntityFlag_Movable|EntityFlag_Collides);

        add_pbd_soft_body_bipyramid_entity(game_state, &pbd_arena, 
                                             V3(12, 10, 14),
                                             V3(6, 10, 10), V3(13, 9, 10), V3(10, 14, 10),
                                             V3(10, 12, 6),
                                             0.0006f, 1/10.0f, V3(0, 0.2f, 1), EntityFlag_Movable|EntityFlag_Collides);

        add_pbd_soft_body_bipyramid_entity(game_state, &pbd_arena, 
                                             V3(-10, -8, 14),
                                             V3(-14, -10, 7), V3(-6, -10, 9), V3(-10, -6, 10),
                                             V3(-11, -9, 6),
                                              0.01f, 1/10.0f, V3(0, 0.2f, 1), EntityFlag_Movable|EntityFlag_Collides);
#endif

#if 0
        v3 cube_p[] = 
        {
            V3(0, 0, 60), 
            V3(-2, -2, 50), V3(2, -2, 50), V3(0, 2, 50),
            // top
            V3(-2, -2, 60), V3(2, -2, 60), V3(2, 2, 60), V3(-2, 2, 60),
            // bottom
            V3(-2, -2, 50), V3(2, -2, 50), V3(2, 2, 50), V3(-2, 2, 50)
        };
        add_pbd_mesh_entity(game_state, 
                                     &pbd_arena, &game_state->transient_arena, 
                                     cube_p, array_count(cube_p),
                                     0.0006f, 1/10.0f, V3(0.7f, 0.2f, 0), EntityFlag_Movable|EntityFlag_Collides);
#endif

        // TODO(gh) This means we have one vector per every 10m, which is not ideal.
        i32 fluid_cell_count_x = 16;
        i32 fluid_cell_count_y = 16;
        i32 fluid_cell_count_z = 16;
        f32 fluid_cell_dim = 12;
        v3 fluid_cell_left_bottom_p = V3(-fluid_cell_dim*fluid_cell_count_x/2, -fluid_cell_dim*fluid_cell_count_y/2, 0);

        initialize_fluid_cube_mac(&game_state->fluid_cube_mac, &game_state->transient_arena, gpu_work_queue,
                                    fluid_cell_left_bottom_p, V3i(fluid_cell_count_x, fluid_cell_count_y, fluid_cell_count_z), 
                                    fluid_cell_dim);


        game_state->is_initialized = true;
    }

    Camera *game_camera = &game_state->game_camera;
    Camera *debug_camera = &game_state->debug_camera;

    Camera *render_camera = game_camera;
    //render_camera = debug_camera;

    // This is an axis angle rotation, which will be a pure quaternion 
    // when used to update the orientation.
    v3 camera_rotation = V3();
     
    if(render_camera == debug_camera)
    {
        // game_camera->roll += 0.8f * platform_input->dt_per_frame;
    }

    v3 camera_dir = get_camera_lookat(render_camera);
    v3 camera_right = get_camera_right(render_camera);
    v3 camera_up = normalize(cross(camera_right, camera_dir)); 

    f32 camera_rotation_speed = 3.0f * platform_input->dt_per_frame;
    if(platform_input->action_up)
    {
        camera_rotation += camera_rotation_speed * camera_right;
    }
    if(platform_input->action_down)
    {
        camera_rotation -= camera_rotation_speed * camera_right;
    }
    if(platform_input->action_left)
    {
        camera_rotation += camera_rotation_speed * V3(0, 0, 1);
    }
    if(platform_input->action_right)
    {
        camera_rotation -= camera_rotation_speed * V3(0, 0, 1);
    }

    // NOTE(gh) orientation, which is a unit quaternion, has 4 DOF, but we have to have only 3.
    // By normalizing the orientation, we can get 4-1=3DOF
    render_camera->orientation = 
        normalize(render_camera->orientation +
                  0.5f*Quat(0, camera_rotation)*render_camera->orientation);

#if 1

    f32 camera_speed = 30.0f * platform_input->dt_per_frame;
    if(platform_input->move_up)
    {
        render_camera->p += camera_speed*camera_dir;
    }
    if(platform_input->move_down)
    {
        render_camera->p -= camera_speed*camera_dir;
    }
    if(platform_input->move_right)
    {
        render_camera->p += camera_speed*camera_right;
    }
    if(platform_input->move_left)
    {
        render_camera->p += -camera_speed*camera_right;
    }
#endif

    for(u32 entity_index = 0;
            entity_index < game_state->entity_count;
            ++entity_index)
    {
        Entity *entity = game_state->entities + entity_index;
        PBDParticleGroup *group = &entity->particle_group;

        switch(entity->type)
        {
            case EntityType_PBD:
            {
                /*
                   NOTE(gh) A little bit about how PBD works
                   Currently we are using Gauss - Seidel relaxation, which means for every iteration,
                   we are using the updated position to get the new position. However, following
                   http://mmacklin.com/smallsteps.pdf, we aren't solving the constraints with multiple iterations.
                   Instead we divide the dt into small sub steps. This introduces us the following problems.

                   Problem 1. Collision handling
                   Dividing the time step can possibly mean the increased amount of collision detection per frame.
                   We can negate this by doing the collision handling once at the start and hope for the best.

                   Problem 2. Precision
                   In XPBD, a lot of the equations include square(sub_step), which means that f32 might not be
                   sufficient for calculation. For example, if the sub step gets higher than 100, the gravity will stop
                   working due to lost precision. We can limit the number of sub steps(15~20), or use double, which 
                   if fine for the CPU, but bad for the GPU.

                   All PBD starts with the linearization using the taylor expansion(gradient == partial differtiation).
                   C(p + dp) (approx)= C(p) + gradient(C) * dp = 0 ...eq(1)
                   Here, p includes the properties of all the particles that were involved in this constraint.
                   So the eq(1) is equivalent to
                   C(p0, p1 ...) + sum(gradient(C(pi))*dp(i)) = 0

                   However, this equation is undetermined. For example, if the constraint was a distance constraint where
                   the distance between the two particles should be maintained, there are endless possible positions.

                   By limiting the direction of dp to the gradient(C(pi)), the equation can be solved.
                   dp(i) = s*wi*gradient(C(pi)) ... eq(2), 
                   where s is typically called a lagrange multiplier, and wi is a inverse mass of the particle(we'll get to this later).

                   plugging eq(2) to eq(1), we get
                   s = -C/sum(wi*square(gradient(C(pi)))). 

                   Nice thing about having a inverse mass property in eq(2) is that the linear momentum is preserved.
                   For the linear momentum to be preserved, the sum(mi*dp(i)) should be 0.
                   Plugging eq(2) to it, we get s * sum(gradient(C(pi))), which is 0 due to translation invariance(Need to dig into this later).
                   (What about the angular momentum?)
                */
                u32 substep_count = 20;
                f32 sub_dt = platform_input->dt_per_frame/substep_count;
                
#if 1
                for(u32 substep_index = 0;
                        substep_index < substep_count;
                        ++substep_index)
                {
                    // Pre solve
                    for(u32 particle_index = 0;
                            particle_index < group->count;
                            ++particle_index)
                    {
                        PBDParticle *particle = group->particles + particle_index;
                        if(particle->inv_mass > 0.0f)
                        {
                            particle->v += sub_dt * V3(0, 0, -9.8f);
                            // TODO(gh) This damping is wrong,
                            // use the formula from XPBD which involves modified lagrange multiplier
                            particle->v *= 0.999f;

                            particle->prev_p = particle->p;

                            particle->p += sub_dt * particle->v;

                            if(particle->p.z <= 0.0f)
                            {
                                // Revert to the previous position,
                                // and set the z value to 0
                                particle->p = particle->prev_p;
                                particle->p.z = 0.0f;
                                particle->v.z = 0.0f;
                            }
                        }
                    }

                    // Solve every constraints
                    for(u32 constraint_index = 0;
                            constraint_index < group->distance_constraint_count;
                            ++constraint_index)
                    {
                        DistanceConstraint *c = group->distance_constraints + constraint_index;
                        PBDParticle *particle0 = group->particles + c->index0;
                        PBDParticle *particle1 = group->particles + c->index1;

                        if(particle0->inv_mass + particle1->inv_mass != 0.0f)
                        {
                            v3 delta = particle0->p - particle1->p;
                            f32 delta_length = length(delta);
                            if(delta_length != 0.0f)
                            {
                                f32 C = delta_length - c->rest_length;

                                if(C != 0.0f)
                                {
                                    // Gradient of the constraint for each particles that were invovled in the constraint
                                    // So this is actually gradient(C(xi))
                                    v3 gradient0 = normalize(delta);
                                    v3 gradient1 = -gradient0;

                                    // TODO(gh) inv_stiffness stuff seems like it's causing a problem..
                                    // NOTE(gh) inv_mass of the particles are involved
                                    // so that the linear momentum is conserved(otherwise, it might produce the 'ghost force')
                                    f32 a = group->inv_distance_stiffness/square(sub_dt);
                                    f32 lagrange_multiplier = 
                                        -C / (particle0->inv_mass + particle1->inv_mass + a);

                                    if(lagrange_multiplier != 0)
                                    {
                                        // NOTE(gh) delta(xi) = lagrange_multiplier*inv_mass*gradient(xi);
                                        particle0->p += lagrange_multiplier*particle0->inv_mass*gradient0;
                                        particle1->p += lagrange_multiplier*particle1->inv_mass*gradient1;
                                    }
                                }
                            }
                        }
                    }

#if 1
                    // TODO: Solve every volume constraints
                    for(u32 constraint_index = 0;
                            constraint_index < group->volume_constraint_count;
                            ++constraint_index)
                    {
                        VolumeConstraint *c = group->volume_constraints + constraint_index;
                        PBDParticle *particle0 = group->particles + c->index0;
                        PBDParticle *particle1 = group->particles + c->index1;
                        PBDParticle *particle2 = group->particles + c->index2;
                        PBDParticle *particle3 = group->particles + c->index3;

                        f32 one_over_6 = 1/6.0f;
                        v3 gradient1 = one_over_6*cross(particle0->p - particle2->p, particle3->p - particle2->p);
                        v3 gradient2 = one_over_6*cross(particle3->p - particle1->p, particle0->p - particle1->p);
                        v3 gradient3 = one_over_6*cross(particle1->p - particle2->p, particle0->p - particle2->p);
                        // NOTE(gh) Due to translation invariance, the sum of all the gradient should be 0
                        v3 gradient0 = -(gradient1+gradient2+gradient3);

                        f32 volume = get_tetrahedron_volume(particle0->p, particle1->p, particle2->p, particle3->p);
                        f32 C = (volume - c->rest_volume);

                        if(C != 0.0f)
                        {
                            f32 sum_of_all_gradients = particle0->inv_mass*length_square(gradient0) + 
                                                       particle1->inv_mass*length_square(gradient1) + 
                                                       particle2->inv_mass*length_square(gradient2) + 
                                                       particle3->inv_mass*length_square(gradient3);

                            f32 lagrange_multiplier = 
                                -C / (sum_of_all_gradients);

                            particle0->p += lagrange_multiplier*particle0->inv_mass*gradient0;
                            particle1->p += lagrange_multiplier*particle1->inv_mass*gradient1;
                            particle2->p += lagrange_multiplier*particle2->inv_mass*gradient2;
                            particle3->p += lagrange_multiplier*particle3->inv_mass*gradient3;
                        }
                    }
#endif

                    // Post solve
                    for(u32 particle_index = 0;
                            particle_index < group->count;
                            ++particle_index)
                    {
                        PBDParticle *particle = group->particles + particle_index;

                        if(particle->inv_mass > 0.0f)
                        {
                            particle->v = (particle->p - particle->prev_p) / sub_dt;

                            v3 temp_v = particle->v + sub_dt * V3(0, 0, -150.8f);
                            v3 next_frame_p = particle->p + sub_dt * temp_v;
                            if(next_frame_p.x > 20)
                            {
                                int a = 1;
                            }
                        }
                    }
                }
#endif
            }break;
        }
    }

    FluidCubeMAC *fluid_cube = &game_state->fluid_cube_mac;
    // TODO(gh) Only a temporary thing, remove this when we move the whole fluid simluation to the GPU
    platform_render_push_buffer->fluid_cube_v_x = &fluid_cube->v_x;
    platform_render_push_buffer->fluid_cube_v_y = &fluid_cube->v_y;
    platform_render_push_buffer->fluid_cube_v_z = &fluid_cube->v_z;
    platform_render_push_buffer->fluid_cube_min = fluid_cube->min;
    platform_render_push_buffer->fluid_cube_max = fluid_cube->max;
    platform_render_push_buffer->fluid_cube_cell_count = fluid_cube->cell_count;
    platform_render_push_buffer->fluid_cube_cell_dim = fluid_cube->cell_dim;
    platform_render_push_buffer->fluid_cube_v_x_offset = clamp(0, (i32)((i64)fluid_cube->v_x_dest - (i64)fluid_cube->v_x_source), INT32_MAX);
    platform_render_push_buffer->fluid_cube_v_y_offset = clamp(0, (i32)((i64)fluid_cube->v_y_dest - (i64)fluid_cube->v_y_source), INT32_MAX);
    platform_render_push_buffer->fluid_cube_v_z_offset = clamp(0, (i32)((i64)fluid_cube->v_z_dest - (i64)fluid_cube->v_z_source), INT32_MAX);

    // NOTE(gh) Frustum cull the grids
    // NOTE(gh) As this is just a conceptual test, it doesn't matter whether the NDC z is 0 to 1 or -1 to 1
    m4x4 view = camera_transform(game_camera);
    m4x4 proj = perspective_projection_near_is_01(game_camera->fov, 
            game_camera->near, 
            game_camera->far, 
            platform_render_push_buffer->width_over_height);

    m4x4 proj_view = proj * view;

    // TODO(gh) Grid z is assumed to be 15(z+floor), and we need to be more conservative on these
    for(u32 grass_grid_index = 0;
            grass_grid_index < game_state->grass_grid_count_x*game_state->grass_grid_count_y;
            ++grass_grid_index)
    {
        GrassGrid *grid = game_state->grass_grids + grass_grid_index;

        f32 z = 15.0f;
        // TODO(gh) This will not work if the grid was big enough to contain the frustum
        // more concrete way would be the seperating axis test
        v3 min = V3(grid->min, 0);
        v3 max = V3(grid->max, z);

        v3 vertices[] = 
        {
            // bottom
            V3(min.x, min.y, min.z),
            V3(min.x, max.y, min.z),
            V3(max.x, min.y, min.z),
            V3(max.x, max.y, min.z),

            // top
            V3(min.x, min.y, max.z),
            V3(min.x, max.y, max.z),
            V3(max.x, min.y, max.z),
            V3(max.x, max.y, max.z),
        };

        // TODO(gh) Re enable this frustum culling
        grid->should_draw = true;
        for(u32 i = 0;
                i < array_count(vertices) && !grid->should_draw;
                ++i)
        {
            // homogeneous p
            v4 hp = proj_view * V4(vertices[i], 1.0f);

            // We are using projection matrix which puts z to 0 to 1
            if((hp.x >= -hp.w && hp.x <= hp.w) &&
                    (hp.y >= -hp.w && hp.y <= hp.w) &&
                    (hp.z >= 0 && hp.z <= hp.w))
            {
                grid->should_draw = true;
                break;
            }
        }
    }

    // NOTE(gh) render entity start
    init_render_push_buffer(platform_render_push_buffer, render_camera, game_camera,
            game_state->grass_grids, game_state->grass_grid_count_x, game_state->grass_grid_count_y, 
            V3(), true);
    platform_render_push_buffer->enable_shadow = true;
    platform_render_push_buffer->enable_grass_rendering = true;

    if(debug_platform_render_push_buffer)
    {
        init_render_push_buffer(debug_platform_render_push_buffer, render_camera, game_camera,
                    0, 0, 0, V3(), false);
    }

    for(u32 entity_index = 0;
        entity_index < game_state->entity_count;
        ++entity_index)
    {
        Entity *entity = game_state->entities + entity_index;
        switch(entity->type)
        {
            case EntityType_Floor:
            {
#if 1
                // TODO(gh) Don't pass mesh asset ID!!!
                push_mesh_pn(platform_render_push_buffer, 
                          entity->generic_entity_info.position, entity->generic_entity_info.dim, entity->color, 
                          &entity->mesh_assetID,
                          AssetTag_FloorMesh,
                          &game_state->assets);
#endif
            }break;

            case EntityType_PBD:
            {
                PBDParticleGroup *group = &entity->particle_group;

                // TODO(gh) This is rendering all the tetradrons, 
                // but we would wanna 'skin' it by rendering only the surfaces
                // and maybe toggle between those
                for(u32 c_index = 0;
                        c_index < group->volume_constraint_count;
                        ++c_index)
                {
                    // TODO(gh) Use push_mesh_pn, but by updating the gpu side buffer
                    // every frame?
                    VolumeConstraint *c = group->volume_constraints + c_index;
                    PBDParticle *part0 = group->particles + c->index0;
                    PBDParticle *part1 = group->particles + c->index1;
                    PBDParticle *part2 = group->particles + c->index2;
                    PBDParticle *part3 = group->particles + c->index3;

                    f32 scale = 1.0f;
                    if(group->volume_constraint_count >= 4)
                    {
                        scale = 0.4f;
                    }
                    v3 center = 0.25f * (part0->p + part1->p + part2->p + part3->p);
                    v3 p0 = scale*(part0->p - center) + center;
                    v3 p1 = scale*(part1->p - center) + center;
                    v3 p2 = scale*(part2->p - center) + center;
                    v3 p3 = scale*(part3->p - center) + center;

                    v3 n013 = normalize(cross(p0 - p1, p3 - p1));
                    v3 n123 = normalize(cross(p2 - p1, p3 - p1));
                    v3 n320 = normalize(cross(p3 - p2, p0 - p2));
                    v3 n102 = normalize(cross(p2 - p1, p0 - p1));

                    VertexPN vertices[] = 
                    {
                        // 0, 3, 1, 
                        {p0, n013},
                        {p3, n013},
                        {p1, n013},
                        // 1, 3, 2, 
                        {p1, n123},
                        {p3, n123},
                        {p2, n123},
                        // 3, 0, 2,
                        {p3, n320},
                        {p0, n320},
                        {p2, n320},
                        // 1, 2, 0,
                        {p1, n102},
                        {p2, n102},
                        {p0, n102},
                    };
                    u32 vertex_count = array_count(vertices);

                    u32 indices[] = 
                    {
                        0, 1, 2, 
                        3, 4, 5, 
                        6, 7, 8, 
                        9, 10, 11
                    };
                    u32 index_count = array_count(indices);

                    push_arbitrary_mesh(platform_render_push_buffer, 
                                        entity->color, 
                                        vertices, vertex_count, 
                                        indices, index_count);

                    push_line(platform_render_push_buffer, p0, p1, entity->color);
                    push_line(platform_render_push_buffer, p1, p2, entity->color);
                    push_line(platform_render_push_buffer, p2, p0, entity->color);

                    push_line(platform_render_push_buffer, p3, p0, entity->color);
                    push_line(platform_render_push_buffer, p3, p1, entity->color);
                    push_line(platform_render_push_buffer, p3, p2, entity->color);
                }
            }break;
        }
    }

    if(debug_platform_render_push_buffer)
    {
        // NOTE(gh) push forward render entries
        b32 enable_show_game_camera_frustum = (render_camera != game_camera);
        if(enable_show_game_camera_frustum)
        {
            CameraFrustum game_camera_frustum = {};
            get_camera_frustum(game_camera, &game_camera_frustum, platform_render_push_buffer->width_over_height);

            /*
               NOTE(gh)
               When looked from the camera p
               near
               0     1
               -------
               |     |
               |     |
               -------
               2     3

               far
               4     5
               -------
               |     |
               |     |
               -------
               6     7
               */
            v3 frustum_vertices[] = 
            {
                game_camera_frustum.near[0],
                game_camera_frustum.near[1],
                game_camera_frustum.near[2],
                game_camera_frustum.near[3],

                game_camera_frustum.far[0],
                game_camera_frustum.far[1],
                game_camera_frustum.far[2],
                game_camera_frustum.far[3],
            };

            u32 frustum_indices[] =
            {
                // top
                0, 1, 4,
                1, 5, 4,

                // right
                1, 3, 5,
                3, 7, 5,

                // left
                2, 0, 6,
                0, 4, 6,

                // bottom
                6, 7, 2,
                7, 3, 2,

                // near
                2, 3, 0,
                3, 1, 0,

                //far
                7, 6, 5,
                6, 4, 5,
            };

            push_frustum(debug_platform_render_push_buffer, V3(0, 0.2f, 1), 
                    frustum_vertices, array_count(frustum_vertices),
                    frustum_indices, array_count(frustum_indices));

            v3 line_color = V3(0, 1, 1);

            push_line(debug_platform_render_push_buffer, game_camera_frustum.near[0], game_camera_frustum.near[1], line_color);
            push_line(debug_platform_render_push_buffer, game_camera_frustum.near[1], game_camera_frustum.near[3], line_color);
            push_line(debug_platform_render_push_buffer, game_camera_frustum.near[2], game_camera_frustum.near[3], line_color);
            push_line(debug_platform_render_push_buffer, game_camera_frustum.near[2], game_camera_frustum.near[0], line_color);

            push_line(debug_platform_render_push_buffer, game_camera_frustum.far[0], game_camera_frustum.far[1], line_color);
            push_line(debug_platform_render_push_buffer, game_camera_frustum.far[1], game_camera_frustum.far[3], line_color);
            push_line(debug_platform_render_push_buffer, game_camera_frustum.far[3], game_camera_frustum.far[2], line_color);
            push_line(debug_platform_render_push_buffer, game_camera_frustum.far[2], game_camera_frustum.far[0], line_color);

            push_line(debug_platform_render_push_buffer, game_camera_frustum.near[0], game_camera_frustum.far[0], line_color);
            push_line(debug_platform_render_push_buffer, game_camera_frustum.near[1], game_camera_frustum.far[1], line_color);
            push_line(debug_platform_render_push_buffer, game_camera_frustum.near[2], game_camera_frustum.far[2], line_color);
            push_line(debug_platform_render_push_buffer, game_camera_frustum.near[3], game_camera_frustum.far[3], line_color);
        }

        // TODO(gh) This prevents us from timing the game update and render loop itself 
        output_debug_records(debug_platform_render_push_buffer, &game_state->assets, V2(0, 0));
    }
    
    thread_work_queue->complete_all_thread_work_queue_items(thread_work_queue, true);
}

// TODO(gh) we can use this function to make the p relative to bottom_left!
internal void
debug_reset_text_to_top_left(v2 *p)
{
    *p = V2(0, 0);
}

internal void
debug_text_line(PlatformRenderPushBuffer *platform_render_push_buffer, FontAsset *font_asset, const char *text, v2 top_left_rel_p_px, f32 scale)
{
    const char *c=text;
    while(*c != '\0')
    {
        if(*c != ' ')
        {
            // The texture that we got does not have bearing integrated,
            // which means we have to offset the entry based on the left bearing 
            f32 left_bearing_px = get_glyph_left_bearing_px(font_asset, scale, *c);
            push_glyph(platform_render_push_buffer, font_asset, 
                    V3(1, 1, 1), top_left_rel_p_px + V2(left_bearing_px, 0), *c, scale);
        }

        // NOTE(gh) check out https://freetype.org/freetype2/docs/tutorial/step2.html
        // for the terms

        f32 x_advance_px = get_glyph_x_advance_px(font_asset, scale, *c);
        if(*(c+1) != '\0')
        {
            f32 kerning = get_glyph_kerning(font_asset, scale, *(c), *(c+1));
            x_advance_px += (kerning);
        }

        top_left_rel_p_px.x += x_advance_px;
        c++;
    }
}

internal void
debug_newline(v2 *top_down_p, f32 scale, FontAsset *font_asset)
{
    top_down_p->x = 0;
    // TODO(gh) I don't like the fact that this function has to 'know' what font asset it is using..
    top_down_p->y += scale*(font_asset->ascent_from_baseline + 
                            font_asset->descent_from_baseline + 
                            font_asset->line_gap);
}

// NOTE(gh) This counter value will be inserted at at the end of the compilation, meaning this array will be large enough
// to contain all the records that we time_blocked in other codes
DebugRecord game_debug_records[__COUNTER__];

#include <stdio.h>
internal void
output_debug_records(PlatformRenderPushBuffer *platform_render_push_buffer, GameAssets *assets, v2 top_left_rel_p_px)
{
    FontAsset *font_asset = &assets->debug_font_asset;
#if 1
    {
        f32 scale = 1.5f;
        // This does not take account of kerning, but
        // kanji might not have kerning at all
        push_glyph(platform_render_push_buffer, font_asset, 
                    V3(1, 1, 1), top_left_rel_p_px, 0x8349, scale);
        top_left_rel_p_px.x += get_glyph_x_advance_px(font_asset, scale, 0x8349);

        top_left_rel_p_px.x += get_glyph_x_advance_px(font_asset, scale, ' ');

        push_glyph(platform_render_push_buffer, font_asset, 
                    V3(1, 1, 1), top_left_rel_p_px, 0x30a8, scale);
        top_left_rel_p_px.x += get_glyph_x_advance_px(font_asset, scale, 0x8349);

        push_glyph(platform_render_push_buffer, font_asset, 
                    V3(1, 1, 1), top_left_rel_p_px, 0x30f3, scale);
        top_left_rel_p_px.x += get_glyph_x_advance_px(font_asset, scale, 0x8349);

        push_glyph(platform_render_push_buffer, font_asset, 
                    V3(1, 1, 1), top_left_rel_p_px, 0x30b8, scale);
        top_left_rel_p_px.x += get_glyph_x_advance_px(font_asset, scale, 0x8349);

        push_glyph(platform_render_push_buffer, font_asset, 
                    V3(1, 1, 1), top_left_rel_p_px, 0x30f3, scale);
        top_left_rel_p_px.x += get_glyph_x_advance_px(font_asset, scale, 0x8349);

        debug_newline(&top_left_rel_p_px, scale, font_asset);
    }
#endif
#if HB_DEBUG
    u64 total_cycle_count = 0;
    for(u32 record_index = 0;
            record_index < array_count(game_debug_records);
            ++record_index)
    {
        DebugRecord *record = game_debug_records + record_index;
        if(record->function)
        {
            const char *function = record->function;
            const char *file = record->file;
            u32 line = record->line;
            u32 hit_count = record->hit_count_cycle_count >> 32;
            u32 cycle_count = (u32)(record->hit_count_cycle_count & 0xffffffff);

            total_cycle_count += cycle_count;

            char buffer[512] = {};
            snprintf(buffer, array_count(buffer),
                    "%s(%s(%u)): %ucy, %uh, %ucy/h ", function, file, line, cycle_count, hit_count, cycle_count/hit_count);

            // TODO(gh) Do we wanna keep this scale value?
            f32 scale = 0.5f;
#if 1
            debug_text_line(platform_render_push_buffer, font_asset, buffer, top_left_rel_p_px, scale);
            debug_newline(&top_left_rel_p_px, scale, &assets->debug_font_asset);
#endif

            atomic_exchange(&record->hit_count_cycle_count, 0);
        }
    }

#if 1 
    {
        char buffer[512] = {};
        snprintf(buffer, array_count(buffer),
                "total cycle count : %llu", total_cycle_count);
        // TODO(gh) Do we wanna keep this scale value?
        f32 scale = 0.5f;
        debug_text_line(platform_render_push_buffer, font_asset, buffer, top_left_rel_p_px, scale);
    }
#endif
#endif
}



