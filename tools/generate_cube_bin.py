#!/usr/bin/env python3
"""Generate binary geometry data for a cube with 6 separate faces.

Each face is a quad with 4 vertices and 2 triangles.
Vertices are ordered CCW when viewed from outside the cube (along the normal direction).
This ensures proper front-face culling behavior.
"""

import struct
import os

def write_face_data(f, positions, normal, uvs, indices):
    """Write a single face's geometry data to the file."""
    # Write positions (4 vertices, VEC3, float32)
    for pos in positions:
        f.write(struct.pack('<3f', *pos))

    # Write normals (4 vertices, VEC3, float32)
    for _ in range(4):
        f.write(struct.pack('<3f', *normal))

    # Write UVs (4 vertices, VEC2, float32)
    for uv in uvs:
        f.write(struct.pack('<2f', *uv))

    # Write indices (6 indices, uint16)
    for idx in indices:
        f.write(struct.pack('<H', idx))

def main():
    output_path = os.path.join(
        os.path.dirname(os.path.dirname(__file__)),
        'resources', 'models', 'displaced_cube', 'displaced_cube.bin'
    )

    # Standard indices for a quad (two triangles, CCW winding)
    # Triangle 1: 0-1-2, Triangle 2: 0-2-3
    indices = [0, 1, 2, 0, 2, 3]

    with open(output_path, 'wb') as f:
        # Front face (+Z) - Normal points toward viewer (+Z)
        # Looking at front face from +Z: bottom-left, bottom-right, top-right, top-left (CCW)
        write_face_data(f,
            positions=[(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)],
            normal=(0, 0, 1),
            uvs=[(0, 0), (1, 0), (1, 1), (0, 1)],
            indices=indices
        )

        # Back face (-Z) - Normal points away from viewer (-Z)
        # Looking at back face from -Z: we see it from behind
        # From -Z looking at the back: bottom-left is (1,-1,-1), bottom-right is (-1,-1,-1)
        write_face_data(f,
            positions=[(1, -1, -1), (-1, -1, -1), (-1, 1, -1), (1, 1, -1)],
            normal=(0, 0, -1),
            uvs=[(0, 0), (1, 0), (1, 1), (0, 1)],
            indices=indices
        )

        # Top face (+Y) - Normal points up (+Y)
        # Looking at top face from +Y (from above):
        # bottom-left is (-1, 1, -1), bottom-right is (1, 1, -1), top-right is (1, 1, 1), top-left is (-1, 1, 1)
        write_face_data(f,
            positions=[(-1, 1, -1), (1, 1, -1), (1, 1, 1), (-1, 1, 1)],
            normal=(0, 1, 0),
            uvs=[(0, 0), (1, 0), (1, 1), (0, 1)],
            indices=indices
        )

        # Bottom face (-Y) - Normal points down (-Y)
        # Looking at bottom face from -Y (from below):
        # bottom-left is (-1, -1, 1), bottom-right is (1, -1, 1), top-right is (1, -1, -1), top-left is (-1, -1, -1)
        write_face_data(f,
            positions=[(-1, -1, 1), (1, -1, 1), (1, -1, -1), (-1, -1, -1)],
            normal=(0, -1, 0),
            uvs=[(0, 0), (1, 0), (1, 1), (0, 1)],
            indices=indices
        )

        # Right face (+X) - Normal points right (+X)
        # Looking at right face from +X:
        # bottom-left is (1, -1, 1), bottom-right is (1, -1, -1), top-right is (1, 1, -1), top-left is (1, 1, 1)
        write_face_data(f,
            positions=[(1, -1, 1), (1, -1, -1), (1, 1, -1), (1, 1, 1)],
            normal=(1, 0, 0),
            uvs=[(0, 0), (1, 0), (1, 1), (0, 1)],
            indices=indices
        )

        # Left face (-X) - Normal points left (-X)
        # Looking at left face from -X:
        # bottom-left is (-1, -1, -1), bottom-right is (-1, -1, 1), top-right is (-1, 1, 1), top-left is (-1, 1, -1)
        write_face_data(f,
            positions=[(-1, -1, -1), (-1, -1, 1), (-1, 1, 1), (-1, 1, -1)],
            normal=(-1, 0, 0),
            uvs=[(0, 0), (1, 0), (1, 1), (0, 1)],
            indices=indices
        )

    print(f"Generated {output_path}")
    print(f"File size: {os.path.getsize(output_path)} bytes (expected: 840)")

if __name__ == '__main__':
    main()
