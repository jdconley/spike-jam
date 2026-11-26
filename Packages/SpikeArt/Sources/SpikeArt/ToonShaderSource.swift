/// The toon surface shader, compiled from source at run time.
///
/// Why source and not a `.metal` file: Xcode 26 ships the Metal compiler as a separate download
/// (`xcodebuild -downloadComponent MetalToolchain`), and SwiftPM's `swift build` doesn't compile
/// `.metal` resources at all. Compiling at run time keeps the package buildable on any machine,
/// and the banded `UnlitMaterial` covers anywhere this fails to build.
///
/// RealityKit links a surface shader against its `[[visible]]` API functions by name. Without the
/// SDK header at run time, the shader declares the handful it calls itself, with the same
/// namespaces and signatures as `<RealityKit/RealityKitSurfaceShader.h>`, so the names match.
///
/// Inputs:
/// - `base_color_tint` × the base-color texture: the flat albedo (jersey atlases, skin);
/// - `custom.value.xyz`: the world-space direction toward the key light;
/// - `custom.texture`: the ramp, a 256×1 strip indexed by `n · l` remapped to 0...1, from `ArtStyle`.
enum ToonShaderSource {
    static let functionName = "spikeArtToonSurface"

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    namespace realitykit {
    namespace texture {
        struct texture_data_t;
        namespace api {
            [[visible]] texture2d<half> base_color(thread texture_data_t &data);
            [[visible]] texture2d<half> custom(thread texture_data_t &data);
        }
    }
    namespace material {
        struct material_constants_t;
        namespace api {
            [[visible]] float3 base_color_tint(thread material_constants_t &data);
        }
    }
    namespace surface {
        struct surface_data_t;
        namespace api {
            [[visible]] thread texture::texture_data_t &textures(thread surface_data_t &data);
            [[visible]] thread material::material_constants_t &material_constants(thread surface_data_t &data);
            [[visible]] float4 custom_parameter(thread surface_data_t &data);
            [[visible]] float3 geometry_normal(thread surface_data_t &data);
            [[visible]] float2 uv0(thread surface_data_t &data);
            [[visible]] void set_base_color(half3 value, thread surface_data_t &data);
            [[visible]] void set_emissive_color(half3 value, thread surface_data_t &data);
            [[visible]] void set_roughness(half value, thread surface_data_t &data);
            [[visible]] void set_metallic(half value, thread surface_data_t &data);
            [[visible]] void set_specular(half value, thread surface_data_t &data);
        }
    }
    struct surface_parameters {
        thread surface::surface_data_t &data;
    };
    }

    [[visible]]
    void \(functionName)(realitykit::surface_parameters params)
    {
        namespace api = realitykit::surface::api;
        thread auto &d = params.data;
        constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
        constexpr sampler nearest(coord::normalized, address::clamp_to_edge, filter::nearest);

        float2 uv = api::uv0(d);
        uv.y = 1.0 - uv.y;
        half3 albedo = realitykit::texture::api::base_color(api::textures(d)).sample(linear, uv).rgb;
        albedo *= half3(realitykit::material::api::base_color_tint(api::material_constants(d)));

        float3 n = normalize(api::geometry_normal(d));
        float3 l = normalize(api::custom_parameter(d).xyz);
        float t = saturate(dot(n, l) * 0.5 + 0.5);
        half3 ramp = realitykit::texture::api::custom(api::textures(d)).sample(nearest, float2(t, 0.5)).rgb;

        half3 c = albedo * ramp;
        api::set_base_color(half3(0), d);
        api::set_roughness(1.0h, d);
        api::set_metallic(0.0h, d);
        api::set_specular(0.0h, d);
        api::set_emissive_color(c, d);
    }
    """
}
