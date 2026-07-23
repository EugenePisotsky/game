#include <flutter/runtime_effect.glsl>

uniform vec4 uDestination;
uniform vec2 uLogicalSize;
uniform vec2 uPivot;
uniform vec2 uHeightRange;
uniform vec3 uObjectPosition;
uniform vec3 uLightPosition;
uniform vec3 uLightColor;
uniform float uAmbient;
uniform float uIntensity;
uniform float uRadius;
uniform float uVisualizationMode;
uniform float uShadowStrength;
uniform sampler2D uAlbedo;
uniform sampler2D uSurface;

out vec4 fragColor;

vec3 decodeOctahedralNormal(vec2 encoded) {
  vec2 projected = encoded * 2.0 - 1.0;
  vec3 normal = vec3(
    projected.x,
    projected.y,
    1.0 - abs(projected.x) - abs(projected.y)
  );
  if (normal.z < 0.0) {
    normal.xy = (1.0 - abs(normal.yx)) * sign(normal.xy);
  }
  return normalize(normal);
}

void main() {
  vec2 fragment = FlutterFragCoord().xy;
  vec2 uv = (fragment - uDestination.xy) / uDestination.zw;
  if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
    fragColor = vec4(0.0);
    return;
  }

  vec4 albedo = texture(uAlbedo, uv);
  if (albedo.a <= 0.001) {
    fragColor = vec4(0.0);
    return;
  }

  vec4 surface = texture(uSurface, uv);
  vec3 surfaceData = surface.rgb / max(surface.a, 0.001);
  vec3 normal = decodeOctahedralNormal(surfaceData.rg);
  float normalizedHeight = surfaceData.b;

  if (uVisualizationMode > 1.5) {
    fragColor = vec4(vec3(normalizedHeight) * albedo.a, albedo.a);
    return;
  }
  if (uVisualizationMode > 0.5) {
    fragColor = vec4((normal * 0.5 + 0.5) * albedo.a, albedo.a);
    return;
  }

  float height = mix(uHeightRange.x, uHeightRange.y, normalizedHeight);
  vec2 spritePixel = uv * uLogicalSize - uPivot * uLogicalSize;
  float difference = spritePixel.x / 64.0;
  float sum = (spritePixel.y + height * 64.0) / 45.2548339959;
  vec2 localPosition = vec2(
    (difference + sum) * 0.5,
    (sum - difference) * 0.5
  );
  vec3 worldPosition = uObjectPosition + vec3(localPosition, height);
  vec3 toLight = uLightPosition - worldPosition;
  float lightDistance = length(toLight);
  vec3 lightDirection = toLight / max(lightDistance, 0.0001);
  float diffuse = max(dot(normal, lightDirection), 0.0);
  float falloff = clamp(1.0 - lightDistance / uRadius, 0.0, 1.0);
  falloff *= falloff;

  vec3 lightLocal = uLightPosition - uObjectPosition;
  vec2 lightSpritePixel = vec2(
    (lightLocal.x - lightLocal.y) * 64.0,
    (lightLocal.x + lightLocal.y) * 45.2548339959 - lightLocal.z * 64.0
  ) + uPivot * uLogicalSize;
  vec2 lightUv = lightSpritePixel / uLogicalSize;
  float occluded = 0.0;
  for (int sampleIndex = 1; sampleIndex <= 12; sampleIndex++) {
    float rayProgress = float(sampleIndex) / 13.0;
    vec2 sampleUv = mix(uv, lightUv, rayProgress);
    if (
      sampleUv.x >= 0.0 && sampleUv.y >= 0.0 &&
      sampleUv.x <= 1.0 && sampleUv.y <= 1.0
    ) {
      vec4 blocker = texture(uSurface, sampleUv);
      vec3 blockerData = blocker.rgb / max(blocker.a, 0.001);
      float blockerHeight = mix(
        uHeightRange.x,
        uHeightRange.y,
        blockerData.b
      );
      float rayHeight = mix(height, lightLocal.z, rayProgress);
      float blockerPresent = step(0.01, blocker.a);
      occluded = max(
        occluded,
        blockerPresent * step(rayHeight + 0.08, blockerHeight)
      );
    }
  }
  float shadow = 1.0 - occluded * uShadowStrength;
  vec3 lighting = vec3(uAmbient) +
    uLightColor * diffuse * falloff * uIntensity * shadow;

  fragColor = vec4(albedo.rgb * lighting, albedo.a);
}
