#!/usr/bin/env python3
"""Generate a 3D sphere test model with displacement for debugging RMIP"""
import json
import base64
import struct
import numpy as np
from PIL import Image
import math

def generate_sphere_displacement(size=256):
    """Generate different displacement patterns for debugging."""
    # Create a simple radial gradient (easier to debug)
    x = np.linspace(-1, 1, size)
    y = np.linspace(-1, 1, size)
    xx, yy = np.meshgrid(x, y)

    # Pattern 1: Radial bumps - clear concentric circles
    r = np.sqrt(xx**2 + yy**2)
    z = (np.sin(r * 8 * np.pi) + 1) / 2  # Concentric rings

    img = Image.fromarray((z * 255).astype(np.uint8), mode='L')
    img.save(f"displacement_sphere_{size}.png")
    print(f"Created displacement_sphere_{size}.png (concentric rings)")

    # Pattern 2: Simple gradient for debugging
    z_gradient = (xx + 1) / 2  # Left-to-right gradient
    img2 = Image.fromarray((z_gradient * 255).astype(np.uint8), mode='L')
    img2.save(f"displacement_gradient_{size}.png")
    print(f"Created displacement_gradient_{size}.png (left-right gradient)")

    # Pattern 3: Checkerboard for texel alignment debugging
    checker_size = size // 8
    z_checker = np.zeros((size, size))
    for i in range(size):
        for j in range(size):
            if ((i // checker_size) + (j // checker_size)) % 2 == 0:
                z_checker[i, j] = 1.0
            else:
                z_checker[i, j] = 0.0
    img3 = Image.fromarray((z_checker * 255).astype(np.uint8), mode='L')
    img3.save(f"displacement_checker_{size}.png")
    print(f"Created displacement_checker_{size}.png (checkerboard)")

    # Pattern 4: Single large bump in center
    z_bump = np.exp(-(xx**2 + yy**2) * 4)
    img4 = Image.fromarray((z_bump * 255).astype(np.uint8), mode='L')
    img4.save(f"displacement_bump_{size}.png")
    print(f"Created displacement_bump_{size}.png (single center bump)")

    return f"displacement_sphere_{size}.png"


def create_uv_sphere(radius=1.0, lat_segments=16, lon_segments=32):
    """Create a UV sphere mesh."""
    positions = []
    normals = []
    uvs = []
    indices = []

    # Generate vertices
    for lat in range(lat_segments + 1):
        theta = lat * math.pi / lat_segments  # 0 to pi
        sin_theta = math.sin(theta)
        cos_theta = math.cos(theta)

        for lon in range(lon_segments + 1):
            phi = lon * 2 * math.pi / lon_segments  # 0 to 2*pi
            sin_phi = math.sin(phi)
            cos_phi = math.cos(phi)

            # Position on unit sphere
            x = cos_phi * sin_theta
            y = cos_theta
            z = sin_phi * sin_theta

            # Normal is same as position for unit sphere
            nx, ny, nz = x, y, z

            # Scale by radius
            x *= radius
            y *= radius
            z *= radius

            # UV coordinates
            u = lon / lon_segments
            v = lat / lat_segments

            positions.extend([x, y, z])
            normals.extend([nx, ny, nz])
            uvs.extend([u, v])

    # Generate indices
    for lat in range(lat_segments):
        for lon in range(lon_segments):
            # Current vertex indices
            curr = lat * (lon_segments + 1) + lon
            next_row = curr + lon_segments + 1

            # Two triangles per quad
            # Triangle 1
            indices.extend([curr, next_row, curr + 1])
            # Triangle 2
            indices.extend([curr + 1, next_row, next_row + 1])

    return positions, normals, uvs, indices


def create_cube(size=1.0):
    """Create a simple cube mesh for testing."""
    s = size / 2

    # 8 vertices, but we need 24 (4 per face) for proper normals
    positions = []
    normals = []
    uvs = []
    indices = []

    # Define 6 faces with their vertices
    faces = [
        # Front face (z+)
        ([(-s, -s, s), (s, -s, s), (s, s, s), (-s, s, s)], (0, 0, 1)),
        # Back face (z-)
        ([(-s, -s, -s), (-s, s, -s), (s, s, -s), (s, -s, -s)], (0, 0, -1)),
        # Top face (y+)
        ([(-s, s, -s), (-s, s, s), (s, s, s), (s, s, -s)], (0, 1, 0)),
        # Bottom face (y-)
        ([(-s, -s, -s), (s, -s, -s), (s, -s, s), (-s, -s, s)], (0, -1, 0)),
        # Right face (x+)
        ([(s, -s, -s), (s, s, -s), (s, s, s), (s, -s, s)], (1, 0, 0)),
        # Left face (x-)
        ([(-s, -s, -s), (-s, -s, s), (-s, s, s), (-s, s, -s)], (-1, 0, 0)),
    ]

    face_uvs = [(0, 0), (1, 0), (1, 1), (0, 1)]

    for i, (verts, normal) in enumerate(faces):
        base_idx = len(positions) // 3
        for j, (x, y, z) in enumerate(verts):
            positions.extend([x, y, z])
            normals.extend(normal)
            uvs.extend(face_uvs[j])

        # Two triangles per face
        indices.extend([base_idx, base_idx + 1, base_idx + 2])
        indices.extend([base_idx, base_idx + 2, base_idx + 3])

    return positions, normals, uvs, indices


def create_simple_cube(size=1.0):
    """Create a very simple cube - 8 vertices, 12 triangles, shared normals."""
    s = size / 2

    # 8 corner vertices
    positions = [
        -s, -s, -s,  # 0: left-bottom-back
         s, -s, -s,  # 1: right-bottom-back
         s,  s, -s,  # 2: right-top-back
        -s,  s, -s,  # 3: left-top-back
        -s, -s,  s,  # 4: left-bottom-front
         s, -s,  s,  # 5: right-bottom-front
         s,  s,  s,  # 6: right-top-front
        -s,  s,  s,  # 7: left-top-front
    ]

    # Normals pointing outward from center (approximation)
    normals = []
    for i in range(0, len(positions), 3):
        x, y, z = positions[i], positions[i+1], positions[i+2]
        length = math.sqrt(x*x + y*y + z*z)
        normals.extend([x/length, y/length, z/length])

    # UVs - simple spherical mapping
    uvs = []
    for i in range(0, len(positions), 3):
        x, y, z = positions[i], positions[i+1], positions[i+2]
        # Simple planar UV from XZ
        u = (x / size) + 0.5
        v = (z / size) + 0.5
        uvs.extend([u, v])

    # 12 triangles (2 per face)
    indices = [
        # Front face
        4, 5, 6, 4, 6, 7,
        # Back face
        1, 0, 3, 1, 3, 2,
        # Top face
        7, 6, 2, 7, 2, 3,
        # Bottom face
        0, 1, 5, 0, 5, 4,
        # Right face
        5, 1, 2, 5, 2, 6,
        # Left face
        0, 4, 7, 0, 7, 3,
    ]

    return positions, normals, uvs, indices


def create_gltf(positions, normals, uvs, indices, displacement_texture,
                output_name, factor=0.2, color=[0.8, 0.6, 0.4, 1.0]):
    """Create a glTF file with displacement material."""

    # Compute bounds
    pos_array = np.array(positions).reshape(-1, 3)
    pos_min = pos_array.min(axis=0).tolist()
    pos_max = pos_array.max(axis=0).tolist()

    num_vertices = len(positions) // 3
    num_indices = len(indices)

    # Pack binary data
    pos_bytes = struct.pack(f'{len(positions)}f', *positions)
    norm_bytes = struct.pack(f'{len(normals)}f', *normals)
    uv_bytes = struct.pack(f'{len(uvs)}f', *uvs)

    # Use 32-bit indices if needed
    if num_vertices > 65535:
        idx_bytes = struct.pack(f'{len(indices)}I', *indices)
        idx_component_type = 5125  # UNSIGNED_INT
        idx_byte_length = len(indices) * 4
    else:
        idx_bytes = struct.pack(f'{len(indices)}H', *indices)
        idx_component_type = 5123  # UNSIGNED_SHORT
        idx_byte_length = len(indices) * 2

    # Pad to 4-byte alignment
    while len(idx_bytes) % 4 != 0:
        idx_bytes += b'\x00'

    buffer_data = pos_bytes + norm_bytes + uv_bytes + idx_bytes
    buffer_b64 = base64.b64encode(buffer_data).decode('ascii')

    pos_byte_length = len(positions) * 4
    norm_byte_length = len(normals) * 4
    uv_byte_length = len(uvs) * 4

    gltf = {
        "asset": {"version": "2.0", "generator": "MatForge 3D Test Generator"},
        "extensionsUsed": ["KHR_materials_displacement"],
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": f"Displaced{output_name}"}],
        "meshes": [{
            "name": output_name,
            "primitives": [{
                "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
                "indices": 3,
                "material": 0
            }]
        }],
        "materials": [{
            "name": "DisplacedMaterial",
            "pbrMetallicRoughness": {
                "baseColorFactor": color,
                "metallicFactor": 0.0,
                "roughnessFactor": 0.5
            },
            "extensions": {
                "KHR_materials_displacement": {
                    "displacementGeometryTexture": {"index": 0, "texCoord": 0},
                    "displacementGeometryFactor": factor,
                    "displacementGeometryOffset": 0.0
                }
            }
        }],
        "textures": [{"source": 0}],
        "images": [{"uri": displacement_texture, "mimeType": "image/png"}],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": num_vertices, "type": "VEC3",
             "min": pos_min, "max": pos_max},
            {"bufferView": 1, "componentType": 5126, "count": num_vertices, "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": num_vertices, "type": "VEC2"},
            {"bufferView": 3, "componentType": idx_component_type, "count": num_indices, "type": "SCALAR"}
        ],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": pos_byte_length},
            {"buffer": 0, "byteOffset": pos_byte_length, "byteLength": norm_byte_length},
            {"buffer": 0, "byteOffset": pos_byte_length + norm_byte_length, "byteLength": uv_byte_length},
            {"buffer": 0, "byteOffset": pos_byte_length + norm_byte_length + uv_byte_length,
             "byteLength": len(idx_bytes)}
        ],
        "buffers": [{
            "byteLength": len(buffer_data),
            "uri": f"data:application/octet-stream;base64,{buffer_b64}"
        }]
    }

    filename = f"displaced_{output_name.lower()}.gltf"
    with open(filename, "w") as f:
        json.dump(gltf, f, indent=2)
    print(f"Created {filename} ({num_vertices} vertices, {num_indices // 3} triangles)")
    return filename


def main():
    print("=== Generating 3D Test Models for RMIP Debugging ===\n")

    # Generate displacement textures
    print("1. Generating displacement textures...")
    texture = generate_sphere_displacement(256)
    print()

    # Create UV sphere
    print("2. Creating UV sphere model...")
    positions, normals, uvs, indices = create_uv_sphere(radius=1.0, lat_segments=16, lon_segments=32)
    create_gltf(positions, normals, uvs, indices,
                "displacement_sphere_256.png", "sphere",
                factor=0.3, color=[0.4, 0.6, 0.8, 1.0])  # Blue sphere
    print()

    # Create cube with gradient displacement
    print("3. Creating cube model with gradient displacement...")
    positions, normals, uvs, indices = create_simple_cube(size=2.0)
    create_gltf(positions, normals, uvs, indices,
                "displacement_gradient_256.png", "cube_gradient",
                factor=0.3, color=[0.8, 0.4, 0.4, 1.0])  # Red cube
    print()

    # Create cube with checkerboard displacement
    print("4. Creating cube model with checkerboard displacement...")
    create_gltf(positions, normals, uvs, indices,
                "displacement_checker_256.png", "cube_checker",
                factor=0.3, color=[0.4, 0.8, 0.4, 1.0])  # Green cube
    print()

    # Create sphere with single bump
    print("5. Creating sphere with single center bump...")
    positions, normals, uvs, indices = create_uv_sphere(radius=1.0, lat_segments=24, lon_segments=48)
    create_gltf(positions, normals, uvs, indices,
                "displacement_bump_256.png", "sphere_bump",
                factor=0.5, color=[0.8, 0.8, 0.4, 1.0])  # Yellow sphere
    print()

    print("=== Done! Generated files: ===")
    print("- displaced_sphere.gltf (concentric rings on blue sphere)")
    print("- displaced_cube_gradient.gltf (gradient on red cube)")
    print("- displaced_cube_checker.gltf (checkerboard on green cube)")
    print("- displaced_sphere_bump.gltf (single bump on yellow sphere)")
    print("\nTest these to identify the source of rendering artifacts:")
    print("- If sphere looks wrong: issue with curved normals")
    print("- If cube looks wrong: issue with planar geometry")
    print("- If checkerboard has gaps: texel marching missing texels")
    print("- If gradient shows steps: micro-geometry tessellation issue")


if __name__ == "__main__":
    main()
