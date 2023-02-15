/*
 * Written by Gyuhyun Lee
 */

#include "hb_entity.h"

// TODO(gh) Fixed particle radius, make this dynamic(might sacrifice stability)
#define particle_radius 1.0f

internal b32
is_entity_flag_set(u32 flags, EntityFlag flag)
{
    b32 result = false;
    if(flags & flag)
    {
        result = true;
    }
    
    return result;
}

internal Entity *
add_entity(GameState *game_state, EntityType type, u32 flags)
{
    Entity *entity = game_state->entities + game_state->entity_count++;

    assert(game_state->entity_count <= game_state->max_entity_count);

    entity->type = type;
    entity->flags = flags;

    return entity;
}

f32 cube_vertices[] = 
{
    // -x
    -0.5f,-0.5f,-0.5f,  -1, 0, 0,
    -0.5f,-0.5f, 0.5f,  -1, 0, 0,
    -0.5f, 0.5f, 0.5f,  -1, 0, 0,

    // -z
    0.5f, 0.5f,-0.5f,  0, 0, -1,
    -0.5f,-0.5f,-0.5f,  0, 0, -1,
    -0.5f, 0.5f,-0.5f,  0, 0, -1,

    // -y
    0.5f,-0.5f, 0.5f,  0, -1, 0,
    -0.5f,-0.5f,-0.5f,  0, -1, 0,
    0.5f,-0.5f,-0.5f,  0, -1, 0,

    // -z
    0.5f, 0.5f,-0.5f,  0, 0, -1,
    0.5f,-0.5f,-0.5f,  0, 0, -1,
    -0.5f,-0.5f,-0.5f,  0, 0, -1,

    // -x
    -0.5f,-0.5f,-0.5f,  -1, 0, 0,
    -0.5f, 0.5f, 0.5f,  -1, 0, 0,
    -0.5f, 0.5f,-0.5f,  -1, 0, 0,

    // -y
    0.5f,-0.5f, 0.5f,  0, -1, 0,
    -0.5f,-0.5f, 0.5f,  0, -1, 0,
    -0.5f,-0.5f,-0.5f,  0, -1, 0,

    // +z
    -0.5f, 0.5f, 0.5f,  0, 0, 1,
    -0.5f,-0.5f, 0.5f,  0, 0, 1,
    0.5f,-0.5f, 0.5f,  0, 0, 1,

    // +x
    0.5f, 0.5f, 0.5f,  1, 0, 0,
    0.5f,-0.5f,-0.5f,  1, 0, 0,
    0.5f, 0.5f,-0.5f,  1, 0, 0,

    // +x
    0.5f,-0.5f,-0.5f,  1, 0, 0,
    0.5f, 0.5f, 0.5f,  1, 0, 0,
    0.5f,-0.5f, 0.5f,  1, 0, 0,

    // +y
    0.5f, 0.5f, 0.5f,  0, 1, 0,
    0.5f, 0.5f,-0.5f,  0, 1, 0,
    -0.5f, 0.5f,-0.5f,  0, 1, 0,

    // +y
    0.5f, 0.5f, 0.5f,  0, 1, 0,
    -0.5f, 0.5f,-0.5f,  0, 1, 0,
    -0.5f, 0.5f, 0.5f,  0, 1, 0,

    // +z
    0.5f, 0.5f, 0.5f,  0, 0, 1,
    -0.5f, 0.5f, 0.5f,  0, 0, 1,
    0.5f,-0.5f, 0.5f,   0, 0, 1,
};

internal Entity *
add_floor_entity(GameState *game_state, MemoryArena *arena, v3 center, v2 dim, v3 color, u32 x_quad_count, u32 y_quad_count,
                 f32 max_height)
{
    Entity *result = add_entity(game_state, EntityType_Floor, EntityFlag_Collides);

    // This is render p and dim, not the acutal dim
    result->generic_entity_info.position = center; 
    result->generic_entity_info.dim = V3(dim, 1);

    result->color = color;

    return result;
}

internal Entity *
add_pbd_rigid_body_cube_entity(GameState *game_state, v3d center, v3 dim, v3 color, f32 inv_mass, u32 flags)
{
    Entity *result = add_entity(game_state, EntityType_Cube, flags);

    result->color = color;

    f32 particle_diameter = 2.0f*particle_radius;
    u32 particle_x_count = ceil_f32_to_u32(dim.x / particle_diameter);
    u32 particle_y_count = ceil_f32_to_u32(dim.y / particle_diameter);
    u32 particle_z_count = ceil_f32_to_u32(dim.z / particle_diameter);

    u32 total_particle_count = particle_x_count *
                               particle_y_count *
                               particle_z_count;

    f32 inv_particle_mass = total_particle_count*inv_mass;

    start_particle_allocation_from_pool(&game_state->particle_pool, &result->particle_group);

    // NOTE(gh) This complicated equation comes from the fact that the 'center' should be different 
    // based on whether the particle count was even or odd.
    v3d left_bottom_particle_center = 
        center - ((f64)particle_diameter * V3d((particle_x_count-1)/2.0,
                                      (particle_y_count-1)/2.0,
                                      (particle_z_count-1)/2.0));
    u32 z_index = 0;
    for(u32 z = 0;
            z < particle_z_count;
            ++z)
    {
        u32 y_index = 0;
        for(u32 y = 0;
                y < particle_y_count;
                ++y)
        {
            for(u32 x = 0;
                    x < particle_x_count;
                    ++x)
            {
                allocate_particle_from_pool(&game_state->particle_pool, 
                                            left_bottom_particle_center + particle_diameter*V3d(x, y, z),
                                            particle_radius,
                                            inv_particle_mass);
            }

            y_index += particle_x_count;
        }

        z_index += particle_x_count*particle_y_count;
    }

    end_particle_allocation_from_pool(&game_state->particle_pool, &result->particle_group);

    return result;
}

internal void
add_distance_constraint(PBDParticleGroup *group, u32 index0, u32 index1)
{
    // TODO(gh) First, search through the constraints to see if there is a duplicate.
    // This is a very slow operation that scales horribly, so might be better if we 
    // can use maybe hashing??

    b32 should_add_new_constraint = true;
    for(u32 c_index = 0;
            c_index < group->distance_constraint_count;
            ++c_index)
    {
        DistanceConstraint *c = group->distance_constraints + c_index;
        if((c->index0 == index0 && c->index1 == index1) || 
          (c->index0 == index1 && c->index1 == index0))
        {
            should_add_new_constraint = false;
        }
    }

    if(should_add_new_constraint)
    {
        DistanceConstraint *c = group->distance_constraints + group->distance_constraint_count++;

        c->index0 = index0;
        c->index1 = index1;

        c->rest_length = length(group->particles[index0].p - group->particles[index1].p);
    }
}


internal void
add_volume_constraint(PBDParticleGroup *group, 
                     u32 top, u32 bottom0, u32 bottom1, u32 bottom2)
{
    PBDParticle *particle0 = group->particles + top;
    PBDParticle *particle1 = group->particles + bottom0;
    PBDParticle *particle2 = group->particles + bottom1;
    PBDParticle *particle3 = group->particles + bottom2;

    VolumeConstraint *c = group->volume_constraints + group->volume_constraint_count++;
    c->index0 = top;
    c->index1 = bottom0;
    c->index2 = bottom1;
    c->index3 = bottom2;
    c->rest_volume = get_tetrahedron_volume(particle0->p, particle1->p, particle2->p, particle3->p);
}

// bottom 3 point should be in counter clockwise order
internal Entity *
add_pbd_soft_body_tetrahedron_entity(GameState *game_state, 
                                MemoryArena *arena,
                                v3d top,
                                v3d bottom_p0, v3d bottom_p1, v3d bottom_p2, 
                                f32 inv_edge_stiffness, f32 inv_mass, v3 color, u32 flags)
{
    Entity *result = add_entity(game_state, EntityType_PBD, flags);
    result->color = color;

    f32 inv_particle_mass = 4 * inv_mass;

    PBDParticleGroup *group = &result->particle_group;

    start_particle_allocation_from_pool(&game_state->particle_pool, group);

    allocate_particle_from_pool(&game_state->particle_pool,
                                top,
                                particle_radius,
                                inv_particle_mass);

    allocate_particle_from_pool(&game_state->particle_pool, 
                                bottom_p0,
                                particle_radius,
                                inv_particle_mass);

    allocate_particle_from_pool(&game_state->particle_pool, 
                                bottom_p1,
                                particle_radius,
                                inv_particle_mass);

    allocate_particle_from_pool(&game_state->particle_pool, 
                                bottom_p2,
                                particle_radius,
                                inv_particle_mass);

    end_particle_allocation_from_pool(&game_state->particle_pool, group);

    group->distance_constraints = push_array(arena, DistanceConstraint, 6);
    group->distance_constraint_count = 0;
    group->inv_distance_stiffness = inv_edge_stiffness;
    add_distance_constraint(group, 0, 1);
    add_distance_constraint(group, 0, 2);
    add_distance_constraint(group, 1, 2);
    add_distance_constraint(group, 0, 3);
    add_distance_constraint(group, 1, 3);
    add_distance_constraint(group, 2, 3);

    group->volume_constraints = push_array(arena, VolumeConstraint, 1);
    group->volume_constraint_count = 0;
    add_volume_constraint(group, 0, 1, 2, 3);

    return result;
}

// NOTE(gh) top p0 and p1 are the vertices perpendicular to the 
// bottom triangle
internal Entity *
add_pbd_soft_body_bipyramid_entity(GameState *game_state, 
                                MemoryArena *arena,
                                v3d top_p0, 
                                v3d bottom_p0, v3d bottom_p1, v3d bottom_p2,
                                v3d top_p1,
                                f32 inv_edge_stiffness, f32 inv_mass, v3 color, u32 flags)
{
    Entity *result = add_entity(game_state, EntityType_PBD, flags);
    result->color = color;

    u32 vertex_count = 5;
    f32 inv_particle_mass = vertex_count * inv_mass;

    PBDParticleGroup *group = &result->particle_group;

    start_particle_allocation_from_pool(&game_state->particle_pool, group);

    allocate_particle_from_pool(&game_state->particle_pool,
                                top_p0,
                                particle_radius,
                                inv_particle_mass);

    allocate_particle_from_pool(&game_state->particle_pool, 
                                bottom_p0,
                                particle_radius,
                                inv_particle_mass);

    allocate_particle_from_pool(&game_state->particle_pool, 
                                bottom_p1,
                                particle_radius,
                                inv_particle_mass);

    allocate_particle_from_pool(&game_state->particle_pool, 
                                bottom_p2,
                                particle_radius,
                                inv_particle_mass);

    allocate_particle_from_pool(&game_state->particle_pool, 
                                top_p1,
                                particle_radius,
                                inv_particle_mass);

    end_particle_allocation_from_pool(&game_state->particle_pool, group);

    group->distance_constraints = push_array(arena, DistanceConstraint, 9);
    group->distance_constraint_count = 0;
    group->inv_distance_stiffness = inv_edge_stiffness;
    add_distance_constraint(group, 0, 1);
    add_distance_constraint(group, 1, 2);
    add_distance_constraint(group, 0, 2);

    add_distance_constraint(group, 0, 3);
    add_distance_constraint(group, 1, 3);
    add_distance_constraint(group, 2, 3);

    add_distance_constraint(group, 0, 4);
    add_distance_constraint(group, 1, 4);
    add_distance_constraint(group, 2, 4);

    group->volume_constraints = push_array(arena, VolumeConstraint, 2);
    group->volume_constraint_count = 0;
    add_volume_constraint(group, 0, 1, 2, 3);
    // TODO(gh) This weird order is due to how we are constructing the vertices
    // dynamically
    add_volume_constraint(group, 1, 2, 3, 4);

    return result;
}

struct Tetrahedron
{
    // top vertex, and the bottom 3 in counter clockwise order
    u32 indices[4];
    b32 being_used;
};

internal u32
push_tetrahedron_vertex(v3 vertex, v3 *t_vertices, u32 *current_count, u32 max_count)
{
    u32 i = *current_count;
    t_vertices[i] = vertex;

    (*current_count)++;
    assert(*current_count <= max_count);

    return i;
}

internal Tetrahedron *
push_tetrahedron(u32 top, 
                 u32 bottom0, u32 bottom1, u32 bottom2, 
                 Tetrahedron *ts, u32 max_count)
{
    Tetrahedron *result = 0;

    for(u32 i = 0;
            i < max_count;
            ++i)
    {
        Tetrahedron *t = ts + i;
        if(!t->being_used)
        {
            result = t;
            break;
        }
    }
    assert(result);

    result->indices[0] = top;
    result->indices[1] = bottom0;
    result->indices[2] = bottom1;
    result->indices[3] = bottom2;
    result->being_used = true;

    return result;
}

#if 0
internal Entity *
add_pbd_mesh_entity(GameState *game_state, 
                    MemoryArena *arena, MemoryArena *temp_arena, 
                    v3 *vertices, u32 vertex_count,
                    f32 inv_edge_stiffness, f32 inv_mass, v3 color, u32 flags)
{
    Entity *result = add_entity(game_state, EntityType_PBD, flags);
    result->color = color;

    v3d center = {};
    f32 max_distance_square = flt_min;
    if(vertex_count > 1)
    {
        for(u32 i = 0;
                i < vertex_count;
                ++i)
        {
            center += vertices[i];
        }
        center /= vertex_count;

        // Find the bounding sphere of the mesh
        max_distance_square = length_square(vertices[0] - center);
    }
    else
    {
        // NOTE(gh) We only have one vertex, so set the center to that vertex
        // and set the arbitrary distance
        center = vertices[0];
        max_distance_square = 1.0f;
    }

    u32 max_teth_count = 8192*4;
    u32 max_teth_vertex_count = 4 * max_teth_count;
    TempMemory temp_memory = start_temp_memory(temp_arena, sizeof(Tetrahedron)*max_teth_count + 
                                                      sizeof(v3) * max_teth_vertex_count);
    Tetrahedron *teths = push_array(&temp_memory, Tetrahedron, max_teth_count);
    v3 *teth_vertices = push_array(&temp_memory, v3, max_teth_vertex_count);
    u32 teth_vertex_count = 0;

    // TODO(gh) Push the first tetrahedron that is big enough 
    // for the bounding sphere of the mesh. The size is a bit ad-hoc
    f32 r = 2.2f*sqrt(max_distance_square);
    // length of the teth edge
    f32 s = 5 * r;
    push_tetrahedron(
        // top
        push_tetrahedron_vertex(center + V3(0, 0, s), teth_vertices, &teth_vertex_count, max_teth_vertex_count),
        // bottom 3
        push_tetrahedron_vertex(center + V3(-s, -s, -s), teth_vertices, &teth_vertex_count, max_teth_vertex_count),
        push_tetrahedron_vertex(center + V3(s, -s, -s), teth_vertices, &teth_vertex_count, max_teth_vertex_count),
        push_tetrahedron_vertex(center + V3(0, s, -s), teth_vertices, &teth_vertex_count, max_teth_vertex_count),
        teths, max_teth_count);

    f32 volume = get_tetrahedron_volume(teth_vertices[0], teth_vertices[1], teth_vertices[2], teth_vertices[3]);

#if 1
    // TODO(gh) Just used for validation, needs to be removed
    for(u32 i = 0;
            i < vertex_count;
            ++i)
    {
        assert(is_inside_tetrahedron(vertices[i], 
                                     teth_vertices[0], teth_vertices[1], teth_vertices[2], teth_vertices[3]));
    }
#endif

    for(u32 vertex_index = 0;
            vertex_index < vertex_count;
            ++vertex_index)
    {
        u32 t_vertexID = push_tetrahedron_vertex(vertices[vertex_index], teth_vertices, &teth_vertex_count, max_teth_vertex_count);

        b32 found_bounding_teth = false;
        for(u32 teth_index = 0;
                !found_bounding_teth && (teth_index < max_teth_count);
                ++teth_index)
        {
            Tetrahedron *teth = teths + teth_index;

            if(teth->being_used && 
                is_inside_tetrahedron(vertices[vertex_index], 
                                     teth_vertices[teth->indices[0]], 
                                     teth_vertices[teth->indices[1]], teth_vertices[teth->indices[2]], teth_vertices[teth->indices[3]]))
            {
                found_bounding_teth = true;

                // If the point was inside the t, we need to make 4 new ts and delete the orignal one
                push_tetrahedron(t_vertexID, teth->indices[0], teth->indices[2], teth->indices[1], teths, max_teth_count);
                push_tetrahedron(t_vertexID, teth->indices[0], teth->indices[3], teth->indices[2], teths, max_teth_count);
                push_tetrahedron(t_vertexID, teth->indices[0], teth->indices[1], teth->indices[3], teths, max_teth_count);
                push_tetrahedron(t_vertexID, teth->indices[1], teth->indices[2], teth->indices[3], teths, max_teth_count);

                teth->being_used = false;

            }
        }

        assert(found_bounding_teth);
    }

    // Validate and remove the teths that contains any of 4 vertices
    // that were encapsulating the bounding sphere of the mesh
    f32 total_volume = 0.0f;
    u32 total_teth_count = 0;
    for(u32 teth_index = 0;
            teth_index < max_teth_count;
            ++teth_index)
    {
        Tetrahedron *teth = teths + teth_index;
        if(teth->being_used)
        {
#if 0
            total_volume += get_tetrahedron_volume(teth_vertices[teth->indices[0]], 
                    teth_vertices[teth->indices[1]],
                    teth_vertices[teth->indices[2]],
                    teth_vertices[teth->indices[3]]);
#endif

            // TODO(gh) If any of the indices were 0, 1, 2, or 3 (vertices of the bounding tetrahedron),
            // we will simply disable that teth
#if 1
            if(teth->indices[0] != 0 && teth->indices[0] != 1 && teth->indices[0] != 2 && teth->indices[0] != 3 &&
               teth->indices[1] != 0 && teth->indices[1] != 1 && teth->indices[1] != 2 && teth->indices[1] != 3 &&
               teth->indices[2] != 0 && teth->indices[2] != 1 && teth->indices[2] != 2 && teth->indices[2] != 3 &&
               teth->indices[3] != 0 && teth->indices[3] != 1 && teth->indices[3] != 2 && teth->indices[3] != 3)
            {
                total_teth_count++;
            }
            else
            {
                teth->being_used = false;
            }
#endif
        }
    }

    if(total_volume > 0.0f)
    {
        assert(abs(volume - total_volume) < 1.0f);
    }

    PBDParticleGroup *group = &result->particle_group;
    f32 inv_particle_mass = vertex_count * inv_mass;

    // NOTE(gh) First, allocate all particles. Note that the bounding tetrahedron's vertices(index 0,1,2,3)
    // will be allocated as where, but they will be neglected since we won't allow any constraints involving 
    // those vertices
    start_particle_allocation_from_pool(&game_state->particle_pool, group);
    for(u32 teth_vertex_index = 0;
            teth_vertex_index < teth_vertex_count;
            ++teth_vertex_index)
    {
        allocate_particle_from_pool(&game_state->particle_pool,
                                    teth_vertices[teth_vertex_index],
                                    particle_radius,
                                    inv_particle_mass);
    }
    end_particle_allocation_from_pool(&game_state->particle_pool, group);

    group->distance_constraints = push_array(arena, DistanceConstraint, 6 * total_teth_count);
    group->distance_constraint_count = 0;
    group->inv_distance_stiffness = inv_edge_stiffness;
    group->volume_constraints = push_array(arena, VolumeConstraint, total_teth_count);
    group->volume_constraint_count = 0;

    for(u32 teth_index = 0;
            teth_index < max_teth_count;
            ++teth_index)
    {
        Tetrahedron * teth = teths + teth_index;
        if(teth->being_used)
        {
            u32 index0 = teth->indices[0];
            u32 index1 = teth->indices[1];
            u32 index2 = teth->indices[2];
            u32 index3 = teth->indices[3];
            add_distance_constraint(group, index0, index1);
            add_distance_constraint(group, index0, index2);
            add_distance_constraint(group, index0, index3);
            add_distance_constraint(group, index1, index2);
            add_distance_constraint(group, index1, index3);
            add_distance_constraint(group, index2, index3);

            add_volume_constraint(group, index0, index1, index2, index3);
        }
    }

    end_temp_memory(&temp_memory);

    return result;
}
#endif











































