#!/usr/bin/env python3
"""Generate a test glTF with KHR_materials_displacement"""
import json
import base64
import struct
import numpy as np
from PIL import Image

def generate_displacement_texture(size=512, pattern="sine"):
    """Generate a displacement texture."""
    x = np.linspace(0, 4*np.pi, size)
    y = np.linspace(0, 4*np.pi, size)
    xx, yy = np.meshgrid(x, y)

    if pattern == "sine":
        z = (np.sin(xx) * np.sin(yy) + 1) / 2  # 0 to 1
    elif pattern == "noise":
        z = np.random.rand(size, size)
        # Smooth it
        from scipy.ndimage import gaussian_filter
        z = gaussian_filter(z, sigma=10)
        z = (z - z.min()) / (z.max() - z.min())
    else:
        z = np.ones((size, size)) * 0.5

    img = Image.fromarray((z * 255).astype(np.uint8), mode='L')
    img.save(f"displacement_{size}.png")
    print(f"Created displacement_{size}.png")
    return f"displacement_{size}.png"

def create_plane_gltf(displacement_texture, factor=0.1):
    """Create a minimal glTF with a displaced plane."""
    # Plane vertices: 4 corners
    positions = [
        -1.0, 0.0, -1.0,  # v0
         1.0, 0.0, -1.0,  # v1
         1.0, 0.0,  1.0,  # v2
        -1.0, 0.0,  1.0,  # v3
    ]
    normals = [0.0, 1.0, 0.0] * 4  # All pointing up
    uvs = [0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0]
    indices = [0, 1, 2, 0, 2, 3]

    # Pack binary data
    pos_bytes = struct.pack(f'{len(positions)}f', *positions)
    norm_bytes = struct.pack(f'{len(normals)}f', *normals)
    uv_bytes = struct.pack(f'{len(uvs)}f', *uvs)
    idx_bytes = struct.pack(f'{len(indices)}H', *indices)

    buffer_data = pos_bytes + norm_bytes + uv_bytes + idx_bytes
    buffer_b64 = base64.b64encode(buffer_data).decode('ascii')

    gltf = {
        "asset": {"version": "2.0", "generator": "MatForge Test Generator"},
        "extensionsUsed": ["KHR_materials_displacement"],
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": "DisplacedPlane"}],
        "meshes": [{
            "name": "Plane",
            "primitives": [{
                "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
                "indices": 3,
                "material": 0
            }]
        }],
        "materials": [{
            "name": "DisplacedMaterial",
            "pbrMetallicRoughness": {
                "baseColorFactor": [0.8, 0.8, 0.8, 1.0],
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
            {"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3",
             "min": [-1, 0, -1], "max": [1, 0, 1]},
            {"bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC2"},
            {"bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR"}
        ],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": 48},
            {"buffer": 0, "byteOffset": 48, "byteLength": 48},
            {"buffer": 0, "byteOffset": 96, "byteLength": 32},
            {"buffer": 0, "byteOffset": 128, "byteLength": 12}
        ],
        "buffers": [{
            "byteLength": len(buffer_data),
            "uri": f"data:application/octet-stream;base64,{buffer_b64}"
        }]
    }

    with open("displaced_plane.gltf", "w") as f:
        json.dump(gltf, f, indent=2)
    print("Created displaced_plane.gltf")

if __name__ == "__main__":
    texture = generate_displacement_texture(512, "sine")
    create_plane_gltf(texture, factor=0.1)