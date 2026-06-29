import { useEffect, useRef } from 'react';

/**
 * NebulaField — a cinematic, continuously-flowing WebGL "star-sea" backdrop.
 *
 * A single fullscreen quad runs an inline GLSL fragment shader that builds:
 *   - domain-warped fbm nebula clouds drifting in teal -> indigo -> violet
 *   - layered parallax star glints (two depths) over near-black
 *   - a slow compass-energy ripple emanating from one focal point
 *
 * Realtime ambient field for the homepage. It replaces the old path/route map
 * layer with a continuous material-like atmosphere, while keeping the same
 * `shouldAnimate` / `variant` integration shape for homepage call sites.
 *
 * Performance / a11y contract:
 *   - devicePixelRatio capped at 2
 *   - requestAnimationFrame loop, paused offscreen (IntersectionObserver)
 *     and on document visibilitychange
 *   - prefers-reduced-motion (or shouldAnimate=false) -> one static frame, no loop
 *   - WebGL context-loss handling + Canvas2D fallback if WebGL is unavailable
 *   - absolutely positioned behind content, pointer-events: none,
 *     with top/bottom fade-to-black so sections melt together
 */

type Variant = 'hero' | 'section';

interface NebulaFieldProps {
  shouldAnimate: boolean;
  variant?: Variant;
  className?: string;
  edgeFades?: boolean;
}

const VERTEX_SRC = `
attribute vec2 aPosition;
void main() {
  gl_Position = vec4(aPosition, 0.0, 1.0);
}
`;

/*
 * Fragment shader. All color constants are the brand palette mapped to 0..1:
 *   near-black  #020617  -> (0.008, 0.024, 0.090)
 *   teal        #2dd4bf  -> (0.176, 0.831, 0.749)
 *   bright teal #7df9ec  -> (0.490, 0.976, 0.925)
 *   sky         #38bdf8  -> (0.220, 0.741, 0.973)
 *   indigo      #818cf8  -> (0.506, 0.549, 0.973)
 *   violet      #7c3aed  -> (0.486, 0.227, 0.929)
 *   soft violet #c4b5fd  -> (0.769, 0.710, 0.992)
 */
const FRAGMENT_SRC = `
precision highp float;

uniform vec2  uResolution;
uniform float uTime;
uniform float uFocal;     // focal/ripple intensity (lower for section variant)
uniform float uStarGain;  // star brightness multiplier

#define NEAR_BLACK vec3(0.008, 0.024, 0.090)
#define TEAL       vec3(0.176, 0.831, 0.749)
#define TEAL_HI    vec3(0.490, 0.976, 0.925)
#define SKY        vec3(0.220, 0.741, 0.973)
#define INDIGO     vec3(0.506, 0.549, 0.973)
#define VIOLET     vec3(0.486, 0.227, 0.929)
#define VIOLET_HI  vec3(0.769, 0.710, 0.992)

// --- hash / value noise -------------------------------------------------
float hash21(vec2 p) {
  p = fract(p * vec2(123.34, 345.45));
  p += dot(p, p + 34.345);
  return fract(p.x * p.y);
}

float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash21(i + vec2(0.0, 0.0));
  float b = hash21(i + vec2(1.0, 0.0));
  float c = hash21(i + vec2(0.0, 1.0));
  float d = hash21(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// fbm — 5 octaves, slowly rotated per octave to avoid grid artifacts
float fbm(vec2 p) {
  float v = 0.0;
  float amp = 0.55;
  mat2 rot = mat2(0.80, 0.60, -0.60, 0.80);
  for (int i = 0; i < 5; i++) {
    v += amp * vnoise(p);
    p = rot * p * 2.02 + 17.3;
    amp *= 0.5;
  }
  return v;
}

// soft additive star layer on a grid; each cell holds one glint
float starLayer(vec2 uv, float density, float twinkleSpeed, float seed) {
  vec2 g = uv * density;
  vec2 cell = floor(g);
  vec2 f = fract(g) - 0.5;
  float rnd = hash21(cell + seed);
  // keep only a sparse subset of cells lit
  float present = step(0.86, rnd);
  vec2 jitter = (vec2(hash21(cell + 7.1 + seed), hash21(cell + 13.7 + seed)) - 0.5) * 0.7;
  float d = length(f - jitter);
  float core = smoothstep(0.045, 0.0, d);
  float halo = smoothstep(0.30, 0.0, d) * 0.35;
  float tw = 0.55 + 0.45 * sin(uTime * twinkleSpeed + rnd * 28.0);
  return (core + halo) * present * tw;
}

void main() {
  vec2 frag = gl_FragCoord.xy;
  vec2 uv = (frag - 0.5 * uResolution) / uResolution.y; // aspect-correct, y in [-0.5,0.5]
  float t = uTime;

  // ---- domain-warped nebula ------------------------------------------
  vec2 p = uv * 1.55;
  // slow global drift
  p += vec2(t * 0.012, t * -0.006);

  // first warp
  vec2 q = vec2(
    fbm(p + vec2(0.0, 0.0) + t * 0.020),
    fbm(p + vec2(5.2, 1.3) - t * 0.015)
  );
  // second warp (domain warping for billowing, video-like flow)
  vec2 r = vec2(
    fbm(p + 3.4 * q + vec2(1.7, 9.2) + t * 0.010),
    fbm(p + 3.4 * q + vec2(8.3, 2.8) - t * 0.012)
  );

  float clouds = fbm(p + 3.8 * r);
  clouds = clamp(clouds, 0.0, 1.0);

  // density shaping — keep large near-black voids so it reads as deep space
  float density = smoothstep(0.42, 0.94, clouds);
  density = pow(density, 1.35);

  // color blend driven by warp fields so hues swirl through the cloud
  float hueA = clamp(r.x * 0.9 + 0.15, 0.0, 1.0);
  float hueB = clamp(q.y * 0.9 + 0.10, 0.0, 1.0);

  vec3 col = NEAR_BLACK;
  vec3 neb = mix(TEAL, INDIGO, smoothstep(0.0, 1.0, hueA));
  neb = mix(neb, VIOLET, smoothstep(0.35, 1.0, hueB));
  // brighter teal/sky highlights in the densest filaments
  neb = mix(neb, mix(TEAL_HI, SKY, hueA), smoothstep(0.55, 1.0, density) * 0.6);

  col = mix(col, neb, density * 0.85);

  // ---- compass-energy ripple from a focal point ----------------------
  // focal point drifts very slightly so it never feels pinned
  vec2 focal = vec2(0.26 + 0.015 * sin(t * 0.05), -0.04 + 0.012 * cos(t * 0.043));
  float fd = length(uv - focal);
  // expanding concentric rings, low amplitude
  float ripple = sin(fd * 26.0 - t * 0.9);
  ripple *= exp(-fd * 3.2);                 // fade with distance
  float ringGlow = exp(-fd * 2.4);          // soft central bloom
  vec3 focalColor = mix(TEAL_HI, VIOLET_HI, 0.4 + 0.3 * sin(t * 0.07));
  col += focalColor * (ripple * 0.05 + ringGlow * 0.06) * uFocal;

  // ---- parallax star glints ------------------------------------------
  // two depths drifting at different speeds -> parallax
  float stars = 0.0;
  stars += starLayer(uv + vec2(t * 0.006, t * 0.002), 26.0, 1.6, 1.0) * 1.0;
  stars += starLayer(uv + vec2(t * 0.012, -t * 0.004), 44.0, 2.3, 9.0) * 0.6;
  vec3 starTint = mix(vec3(1.0), TEAL_HI, 0.35);
  col += starTint * stars * uStarGain;

  // ---- grade ---------------------------------------------------------
  // gentle radial vignette toward black at the edges
  float vig = smoothstep(1.05, 0.25, length(uv * vec2(1.0, 1.18)));
  col *= mix(0.55, 1.0, vig);

  // lift blacks just slightly toward the brand near-black (never pure 0 banding)
  col = max(col, NEAR_BLACK * 0.6);

  // subtle filmic-ish contrast
  col = col / (col + 0.85);
  col = pow(col, vec3(0.92));

  // ordered-dither to kill banding in the smooth gradients
  float dither = (hash21(frag) - 0.5) / 255.0;
  col += dither;

  gl_FragColor = vec4(col, 1.0);
}
`;

function compile(gl: WebGLRenderingContext, type: number, src: string): WebGLShader | null {
  const sh = gl.createShader(type);
  if (!sh) return null;
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    // Surface the error in dev; caller falls back to Canvas2D.
    if (typeof console !== 'undefined') {
      console.warn('[NebulaField] shader compile failed:', gl.getShaderInfoLog(sh));
    }
    gl.deleteShader(sh);
    return null;
  }
  return sh;
}

/** Paint a tasteful static nebula-ish gradient via Canvas2D (fallback + reduced-motion). */
function paintStaticFallback(canvas: HTMLCanvasElement, cssW: number, cssH: number) {
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  canvas.width = Math.max(1, Math.round(cssW * dpr));
  canvas.height = Math.max(1, Math.round(cssH * dpr));
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

  ctx.fillStyle = '#020617';
  ctx.fillRect(0, 0, cssW, cssH);

  const blobs: Array<[number, number, number, string]> = [
    [cssW * 0.26, cssH * 0.42, Math.max(cssW, cssH) * 0.55, 'rgba(45,212,191,0.20)'],
    [cssW * 0.7, cssH * 0.3, Math.max(cssW, cssH) * 0.5, 'rgba(129,140,248,0.18)'],
    [cssW * 0.55, cssH * 0.78, Math.max(cssW, cssH) * 0.6, 'rgba(124,58,237,0.16)'],
    [cssW * 0.85, cssH * 0.65, Math.max(cssW, cssH) * 0.4, 'rgba(56,189,248,0.12)'],
  ];
  ctx.globalCompositeOperation = 'lighter';
  for (const [x, y, rad, color] of blobs) {
    const g = ctx.createRadialGradient(x, y, 0, x, y, rad);
    g.addColorStop(0, color);
    g.addColorStop(1, 'rgba(2,6,23,0)');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, cssW, cssH);
  }

  // sprinkle a few static stars
  ctx.globalCompositeOperation = 'lighter';
  for (let i = 0; i < 90; i++) {
    const x = ((Math.sin(i * 12.9898) * 43758.5453) % 1 + 1) % 1 * cssW;
    const y = ((Math.sin(i * 78.233) * 12543.1234) % 1 + 1) % 1 * cssH;
    const a = 0.25 + (((Math.sin(i * 3.17) * 1000) % 1 + 1) % 1) * 0.5;
    ctx.fillStyle = `rgba(255,255,255,${a.toFixed(3)})`;
    ctx.fillRect(x, y, 1.2, 1.2);
  }
  ctx.globalCompositeOperation = 'source-over';

  // radial vignette toward black
  const v = ctx.createRadialGradient(
    cssW * 0.5, cssH * 0.45, 0,
    cssW * 0.5, cssH * 0.45, Math.max(cssW, cssH) * 0.75,
  );
  v.addColorStop(0, 'rgba(2,6,23,0)');
  v.addColorStop(1, 'rgba(0,0,0,0.85)');
  ctx.fillStyle = v;
  ctx.fillRect(0, 0, cssW, cssH);
}

export function NebulaField({
  shouldAnimate,
  variant = 'hero',
  className = '',
  edgeFades = true,
}: NebulaFieldProps) {
  const wrapRef = useRef<HTMLDivElement | null>(null);
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const wrap = wrapRef.current;
    const canvas = canvasRef.current;
    if (!wrap || !canvas) return;

    const reduceQuery =
      typeof window.matchMedia === 'function'
        ? window.matchMedia('(prefers-reduced-motion: reduce)')
        : null;

    // Per-variant tuning. The section variant is quieter so it never fights content.
    const focal = variant === 'hero' ? 1.0 : 0.55;
    const starGain = variant === 'hero' ? 0.9 : 0.7;

    // --- shared sizing state ------------------------------------------
    const DPR_CAP = 2;
    let cssW = 1;
    let cssH = 1;
    let dpr = Math.min(window.devicePixelRatio || 1, DPR_CAP);
    let disposed = false;

    const measure = () => {
      const rect = wrap.getBoundingClientRect();
      cssW = Math.max(1, rect.width);
      cssH = Math.max(1, rect.height);
      dpr = Math.min(window.devicePixelRatio || 1, DPR_CAP);
    };

    // ==================================================================
    // Reduced-motion / shouldAnimate=false -> single static frame, no loop
    // ==================================================================
    const wantsAnimation = () => shouldAnimate && !(reduceQuery && reduceQuery.matches);

    if (!wantsAnimation()) {
      let disposed = false;
      let resizePending = false;
      let resizeRafId = 0;

      const paintStaticCanvas = () => {
        if (disposed) return;
        measure();
        canvas.style.width = `${cssW}px`;
        canvas.style.height = `${cssH}px`;
        paintStaticFallback(canvas, cssW, cssH);
      };

      const onResize = () => {
        if (disposed || resizePending) return;
        resizePending = true;
        resizeRafId = window.requestAnimationFrame(() => {
          resizeRafId = 0;
          resizePending = false;
          paintStaticCanvas();
        });
      };

      paintStaticCanvas();
      window.addEventListener('resize', onResize);

      return () => {
        disposed = true;
        if (resizeRafId) {
          window.cancelAnimationFrame(resizeRafId);
        }
        window.removeEventListener('resize', onResize);
      };
    }

    // ---- try WebGL ---------------------------------------------------
    const glOpts: WebGLContextAttributes = {
      alpha: false,
      antialias: false,
      depth: false,
      stencil: false,
      premultipliedAlpha: false,
      preserveDrawingBuffer: false,
      powerPreference: 'low-power',
    };
    const gl =
      (canvas.getContext('webgl', glOpts) as WebGLRenderingContext | null) ||
      (canvas.getContext('experimental-webgl', glOpts) as WebGLRenderingContext | null);

    // ------------------------------------------------------------------
    // Canvas2D-only path (no WebGL at all)
    // ------------------------------------------------------------------
    if (!gl) {
      measure();
      paintStaticFallback(canvas, cssW, cssH);
      const onResize = () => {
        measure();
        paintStaticFallback(canvas, cssW, cssH);
      };
      window.addEventListener('resize', onResize);
      return () => window.removeEventListener('resize', onResize);
    }

    // ------------------------------------------------------------------
    // WebGL program setup
    // ------------------------------------------------------------------
    let program: WebGLProgram | null = null;
    let buffer: WebGLBuffer | null = null;
    let aPositionLoc = -1;
    let uResolutionLoc: WebGLUniformLocation | null = null;
    let uTimeLoc: WebGLUniformLocation | null = null;
    let uFocalLoc: WebGLUniformLocation | null = null;
    let uStarGainLoc: WebGLUniformLocation | null = null;
    let glReady = false;

    const buildProgram = (): boolean => {
      const vs = compile(gl, gl.VERTEX_SHADER, VERTEX_SRC);
      const fs = compile(gl, gl.FRAGMENT_SHADER, FRAGMENT_SRC);
      if (!vs || !fs) return false;

      const prog = gl.createProgram();
      if (!prog) return false;
      gl.attachShader(prog, vs);
      gl.attachShader(prog, fs);
      gl.linkProgram(prog);
      // shaders can be detached/deleted once linked
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
        if (typeof console !== 'undefined') {
          console.warn('[NebulaField] program link failed:', gl.getProgramInfoLog(prog));
        }
        return false;
      }
      program = prog;

      buffer = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
      // a single fullscreen triangle (covers the quad with one primitive)
      gl.bufferData(
        gl.ARRAY_BUFFER,
        new Float32Array([-1, -1, 3, -1, -1, 3]),
        gl.STATIC_DRAW,
      );

      aPositionLoc = gl.getAttribLocation(program, 'aPosition');
      uResolutionLoc = gl.getUniformLocation(program, 'uResolution');
      uTimeLoc = gl.getUniformLocation(program, 'uTime');
      uFocalLoc = gl.getUniformLocation(program, 'uFocal');
      uStarGainLoc = gl.getUniformLocation(program, 'uStarGain');
      glReady = true;
      return true;
    };

    const resizeGL = () => {
      measure();
      const w = Math.max(1, Math.round(cssW * dpr));
      const h = Math.max(1, Math.round(cssH * dpr));
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w;
        canvas.height = h;
      }
      gl.viewport(0, 0, w, h);
    };

    const renderGL = (timeSeconds: number) => {
      if (!glReady || !program) return;
      gl.useProgram(program);
      gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
      gl.enableVertexAttribArray(aPositionLoc);
      gl.vertexAttribPointer(aPositionLoc, 2, gl.FLOAT, false, 0, 0);
      if (uResolutionLoc) gl.uniform2f(uResolutionLoc, canvas.width, canvas.height);
      if (uTimeLoc) gl.uniform1f(uTimeLoc, timeSeconds);
      if (uFocalLoc) gl.uniform1f(uFocalLoc, focal);
      if (uStarGainLoc) gl.uniform1f(uStarGainLoc, starGain);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    };

    // ------------------------------------------------------------------
    // Animation loop with offscreen + visibility pausing
    // ------------------------------------------------------------------
    let rafId = 0;
    let running = false;
    let isOnscreen = true;
    // accumulate elapsed time so pausing doesn't cause a jump on resume
    let elapsed = 0;
    let lastTs = 0;

    const frame = (ts: number) => {
      if (!running) return;
      if (lastTs === 0) lastTs = ts;
      const dt = Math.min(0.05, (ts - lastTs) / 1000); // clamp big gaps
      lastTs = ts;
      elapsed += dt;
      renderGL(elapsed);
      rafId = window.requestAnimationFrame(frame);
    };

    const startLoop = () => {
      if (disposed || running || !glReady) return;
      if (!wantsAnimation()) {
        // static frame only
        resizeGL();
        renderGL(elapsed || 6.0); // a nicely-developed frame, not t=0
        return;
      }
      running = true;
      lastTs = 0;
      resizeGL();
      rafId = window.requestAnimationFrame(frame);
    };

    const stopLoop = () => {
      running = false;
      if (rafId) {
        window.cancelAnimationFrame(rafId);
        rafId = 0;
      }
    };

    // render a single static frame (used when animation is not wanted)
    const renderStatic = () => {
      if (disposed || !glReady) return;
      resizeGL();
      renderGL(elapsed || 6.0);
    };

    // ---- context-loss handling --------------------------------------
    const onContextLost = (e: Event) => {
      e.preventDefault(); // required so 'restored' can fire
      stopLoop();
      glReady = false;
    };
    const onContextRestored = () => {
      if (buildProgram()) {
        resizeGL();
        if (wantsAnimation() && isOnscreen) startLoop();
        else renderStatic();
      } else {
        // give up on WebGL — paint the Canvas2D fallback into the same canvas
        measure();
        paintStaticFallback(canvas, cssW, cssH);
      }
    };
    canvas.addEventListener('webglcontextlost', onContextLost, false);
    canvas.addEventListener('webglcontextrestored', onContextRestored, false);

    // ---- build + first paint ----------------------------------------
    if (!buildProgram()) {
      // shader failed to compile/link -> Canvas2D fallback
      measure();
      paintStaticFallback(canvas, cssW, cssH);
      canvas.removeEventListener('webglcontextlost', onContextLost);
      canvas.removeEventListener('webglcontextrestored', onContextRestored);
      const onResize = () => {
        measure();
        paintStaticFallback(canvas, cssW, cssH);
      };
      window.addEventListener('resize', onResize);
      return () => window.removeEventListener('resize', onResize);
    }

    // ---- visibility / intersection pausing --------------------------
    const evaluateRun = () => {
      const animate = wantsAnimation();
      const docVisible = document.visibilityState !== 'hidden';
      if (animate && isOnscreen && docVisible) {
        startLoop();
      } else {
        stopLoop();
        // keep a coherent still frame on screen while paused
        if (!animate) renderStatic();
      }
    };

    const io =
      typeof IntersectionObserver !== 'undefined'
        ? new IntersectionObserver(
            (entries) => {
              for (const entry of entries) {
                isOnscreen = entry.isIntersecting;
              }
              evaluateRun();
            },
            { rootMargin: '120px' },
          )
        : null;
    if (io) io.observe(wrap);
    else isOnscreen = true;

    const onVisibility = () => evaluateRun();
    document.addEventListener('visibilitychange', onVisibility);

    const onReduceChange = () => {
      stopLoop();
      evaluateRun();
    };
    if (reduceQuery) {
      if (reduceQuery.addEventListener) reduceQuery.addEventListener('change', onReduceChange);
      else if ((reduceQuery as MediaQueryList).addListener) {
        (reduceQuery as MediaQueryList).addListener(onReduceChange);
      }
    }

    // resize handling (debounced via rAF coalescing through the loop;
    // when paused we just repaint the static frame)
    let resizePending = false;
    let resizeRafId = 0;
    const onResize = () => {
      if (disposed || resizePending) return;
      resizePending = true;
      resizeRafId = window.requestAnimationFrame(() => {
        resizeRafId = 0;
        if (disposed) return;
        resizePending = false;
        if (running) {
          resizeGL();
        } else {
          renderStatic();
        }
      });
    };
    window.addEventListener('resize', onResize);

    // first paint
    resizeGL();
    if (wantsAnimation()) evaluateRun();
    else renderStatic();

    // ---- cleanup -----------------------------------------------------
    return () => {
      disposed = true;
      stopLoop();
      if (resizeRafId) {
        window.cancelAnimationFrame(resizeRafId);
        resizeRafId = 0;
      }
      if (io) io.disconnect();
      document.removeEventListener('visibilitychange', onVisibility);
      window.removeEventListener('resize', onResize);
      if (reduceQuery) {
        if (reduceQuery.removeEventListener) reduceQuery.removeEventListener('change', onReduceChange);
        else if ((reduceQuery as MediaQueryList).removeListener) {
          (reduceQuery as MediaQueryList).removeListener(onReduceChange);
        }
      }
      canvas.removeEventListener('webglcontextlost', onContextLost);
      canvas.removeEventListener('webglcontextrestored', onContextRestored);
      if (gl) {
        if (buffer) gl.deleteBuffer(buffer);
        if (program) gl.deleteProgram(program);
        const lose = gl.getExtension('WEBGL_lose_context');
        if (lose) lose.loseContext();
      }
    };
  }, [shouldAnimate, variant]);

  // Section variant bleeds slightly past its container so the nebula reads as
  // continuous across stacked sections.
  const inset = variant === 'section' ? '-8% 0' : '0';
  const opacity = variant === 'hero' ? 0.9 : 0.76;
  const motionState = shouldAnimate ? 'animated' : 'static';
  const staticBackground =
    'radial-gradient(circle at 24% 36%, rgba(45, 212, 191, 0.22), transparent 42%), radial-gradient(circle at 72% 28%, rgba(129, 140, 248, 0.18), transparent 46%), radial-gradient(circle at 54% 74%, rgba(124, 58, 237, 0.14), transparent 48%), #020617';

  return (
    <div
      ref={wrapRef}
      className={`nebula-field ${className}`}
      data-variant={variant}
      data-motion={motionState}
      aria-hidden="true"
      style={{
        position: 'absolute',
        inset,
        zIndex: 1,
        overflow: 'hidden',
        pointerEvents: 'none',
        mixBlendMode: 'screen',
        opacity,
        contain: 'layout paint style',
        background: motionState === 'static' ? staticBackground : undefined,
      }}
    >
      <canvas
        ref={canvasRef}
        style={{
          position: 'absolute',
          inset: 0,
          width: '100%',
          height: '100%',
          display: 'block',
        }}
      />
      {edgeFades ? (
        <>
          <div
            style={{
              position: 'absolute',
              left: 0,
              right: 0,
              top: 0,
              height: variant === 'hero' ? 140 : 200,
              background: 'linear-gradient(to bottom, #000 0%, transparent 100%)',
              pointerEvents: 'none',
            }}
          />
          <div
            style={{
              position: 'absolute',
              left: 0,
              right: 0,
              bottom: 0,
              height: variant === 'hero' ? 200 : 200,
              background: 'linear-gradient(to top, #000 0%, transparent 100%)',
              pointerEvents: 'none',
            }}
          />
        </>
      ) : null}
    </div>
  );
}

export default NebulaField;
