#include <flutter/runtime_effect.glsl>

uniform vec4 uDestination;
uniform vec2 uObjectScreen;
uniform vec3 uObjectPosition;
uniform vec3 uLightPosition;
uniform float uReceiverElevation;
uniform float uShadowOpacity;
uniform float uLightRadius;
uniform float uWorldExtent;
uniform float uObjectRotation;
uniform float uProxyHalfWidth;
uniform float uProxyHalfDepth;
uniform float uProxyEaveHeight;
uniform float uProxyRidgeHeight;

out vec4 fragColor;

vec3 worldToProxy(vec3 point) {
  vec3 relative = point - uObjectPosition;
  float cosine = cos(uObjectRotation);
  float sine = sin(uObjectRotation);
  return vec3(
    cosine * relative.x + sine * relative.y,
    -sine * relative.x + cosine * relative.y,
    relative.z
  );
}

bool clipHalfSpace(
  vec3 normal,
  float limit,
  vec3 origin,
  vec3 direction,
  inout float enter,
  inout float leave
) {
  float originDistance = dot(normal, origin) - limit;
  float rate = dot(normal, direction);
  if (abs(rate) < 0.00001) {
    return originDistance <= 0.0;
  }

  float crossing = -originDistance / rate;
  if (rate < 0.0) {
    enter = max(enter, crossing);
  } else {
    leave = min(leave, crossing);
  }
  return enter <= leave;
}

bool intersectsShadowProxy(vec3 receiver, vec3 light) {
  vec3 origin = worldToProxy(receiver);
  vec3 direction = worldToProxy(light) - origin;
  float enter = 0.001;
  float leave = 0.999;
  float roofSlope =
    (uProxyRidgeHeight - uProxyEaveHeight) / uProxyHalfDepth;

  if (!clipHalfSpace(
    vec3(1.0, 0.0, 0.0),
    uProxyHalfWidth,
    origin,
    direction,
    enter,
    leave
  )) return false;
  if (!clipHalfSpace(
    vec3(-1.0, 0.0, 0.0),
    uProxyHalfWidth,
    origin,
    direction,
    enter,
    leave
  )) return false;
  if (!clipHalfSpace(
    vec3(0.0, 1.0, 0.0),
    uProxyHalfDepth,
    origin,
    direction,
    enter,
    leave
  )) return false;
  if (!clipHalfSpace(
    vec3(0.0, -1.0, 0.0),
    uProxyHalfDepth,
    origin,
    direction,
    enter,
    leave
  )) return false;
  if (!clipHalfSpace(
    vec3(0.0, 0.0, -1.0),
    0.0,
    origin,
    direction,
    enter,
    leave
  )) return false;
  if (!clipHalfSpace(
    vec3(0.0, roofSlope, 1.0),
    uProxyRidgeHeight,
    origin,
    direction,
    enter,
    leave
  )) return false;
  if (!clipHalfSpace(
    vec3(0.0, -roofSlope, 1.0),
    uProxyRidgeHeight,
    origin,
    direction,
    enter,
    leave
  )) return false;
  return enter <= leave && leave > 0.001 && enter < 0.999;
}

void main() {
  vec2 fragment = FlutterFragCoord().xy;
  vec2 destinationUv = (fragment - uDestination.xy) / uDestination.zw;
  if (
    destinationUv.x < 0.0 || destinationUv.y < 0.0 ||
    destinationUv.x > 1.0 || destinationUv.y > 1.0
  ) {
    fragColor = vec4(0.0);
    return;
  }

  vec2 groundScreen = fragment - uObjectScreen;
  float difference = groundScreen.x / 64.0;
  float sum = groundScreen.y / 45.2548339959;
  vec2 groundLocal = vec2(
    (difference + sum) * 0.5,
    (sum - difference) * 0.5
  );
  if (
    abs(groundLocal.x) > uWorldExtent ||
    abs(groundLocal.y) > uWorldExtent
  ) {
    fragColor = vec4(0.0);
    return;
  }

  vec3 groundWorld = vec3(
    uObjectPosition.xy + groundLocal,
    uReceiverElevation
  );
  float horizontalDistance = length(uLightPosition.xy - groundWorld.xy);
  if (horizontalDistance > uLightRadius) {
    fragColor = vec4(0.0);
    return;
  }

  float occlusion = intersectsShadowProxy(groundWorld, uLightPosition) ? 1.0 : 0.0;
  float radialFade = 1.0 - smoothstep(
    uLightRadius * 0.75,
    uLightRadius,
    horizontalDistance
  );
  float alpha = occlusion * radialFade * uShadowOpacity;
  vec3 shadowColor = vec3(0.025, 0.035, 0.055);
  fragColor = vec4(shadowColor * alpha, alpha);
}
