/* The MikkTSpace reference tool (ADR-0086, docs/design/environment.md §5.1).
 *
 *     mikktspace_ref <in.mesh> <out.tangents>
 *
 * Reads a corpus mesh (u32 vertex count, u32 index count, then that many f32x3 positions,
 * f32x3 normals, f32x2 UVs and u32 indices, all little-endian), runs the unmodified
 * reference's genTangSpaceDefault over its triangles, and writes one f32x4 per corner:
 * setTSpaceBasic's tangent and sign. Built by scripts/m41/reference.py; never by the build.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mikktspace.h"

typedef struct {
    uint32_t vertex_count, index_count;
    float *positions, *normals, *uvs;
    uint32_t *indices;
    float *out;
} Mesh;

static int faces(const SMikkTSpaceContext *c) { return (int)(((Mesh *)c->m_pUserData)->index_count / 3); }
static int corners(const SMikkTSpaceContext *c, const int f) { (void)c; (void)f; return 3; }
static uint32_t vertex(const SMikkTSpaceContext *c, int f, int i) { return ((Mesh *)c->m_pUserData)->indices[f * 3 + i]; }
static void position(const SMikkTSpaceContext *c, float out[], const int f, const int i) {
    memcpy(out, &((Mesh *)c->m_pUserData)->positions[vertex(c, f, i) * 3], 12);
}
static void normal(const SMikkTSpaceContext *c, float out[], const int f, const int i) {
    memcpy(out, &((Mesh *)c->m_pUserData)->normals[vertex(c, f, i) * 3], 12);
}
static void texcoord(const SMikkTSpaceContext *c, float out[], const int f, const int i) {
    memcpy(out, &((Mesh *)c->m_pUserData)->uvs[vertex(c, f, i) * 2], 8);
}
static void basic(const SMikkTSpaceContext *c, const float t[], const float sign, const int f, const int i) {
    float *o = &((Mesh *)c->m_pUserData)->out[(f * 3 + i) * 4];
    o[0] = t[0]; o[1] = t[1]; o[2] = t[2]; o[3] = sign;
}

static void *slurp(FILE *f, size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p || fread(p, 1, n, f) != n) { fprintf(stderr, "short read\n"); exit(1); }
    return p;
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: mikktspace_ref <in.mesh> <out.tangents>\n"); return 2; }
    FILE *in = fopen(argv[1], "rb");
    if (!in) { perror(argv[1]); return 1; }
    Mesh m;
    uint32_t head[2];
    if (fread(head, 4, 2, in) != 2) { fprintf(stderr, "short read\n"); return 1; }
    m.vertex_count = head[0];
    m.index_count = head[1];
    m.positions = slurp(in, (size_t)m.vertex_count * 12);
    m.normals = slurp(in, (size_t)m.vertex_count * 12);
    m.uvs = slurp(in, (size_t)m.vertex_count * 8);
    m.indices = slurp(in, (size_t)m.index_count * 4);
    fclose(in);
    m.out = calloc((size_t)m.index_count * 4, sizeof(float));

    SMikkTSpaceInterface iface = {0};
    iface.m_getNumFaces = faces;
    iface.m_getNumVerticesOfFace = corners;
    iface.m_getPosition = position;
    iface.m_getNormal = normal;
    iface.m_getTexCoord = texcoord;
    iface.m_setTSpaceBasic = basic;
    SMikkTSpaceContext ctx = {&iface, &m};
    if (!genTangSpaceDefault(&ctx)) { fprintf(stderr, "genTangSpaceDefault failed\n"); return 1; }

    FILE *out = fopen(argv[2], "wb");
    if (!out || fwrite(m.out, 16, m.index_count, out) != m.index_count) { perror(argv[2]); return 1; }
    fclose(out);
    return 0;
}
