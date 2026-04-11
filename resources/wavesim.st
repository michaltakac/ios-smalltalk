"wavesim.st — 2D Wave Propagation Simulation driven by Metal GPU compute.
 All code runs inside Pharo and can be modified live in a Workspace.
 Usage: WaveSimMorph open."!

"======== FFI Bindings ========"!

Object subclass: #WaveSimFFI
    instanceVariableNames: ''
    classVariableNames: ''
    package: 'WaveSim'!

WaveSimFFI class compile: 'ffiLibrary
    ^ LibC' classified: 'ffi'!

WaveSimFFI class compile: 'wavesimInit: width height: height
    ^ self ffiCall: #(void wavesim_init(int width, int height))' classified: 'ffi'!

WaveSimFFI class compile: 'wavesimStep: numSteps
    ^ self ffiCall: #(void wavesim_step(int numSteps))' classified: 'ffi'!

WaveSimFFI class compile: 'wavesimInjectX: x y: y strength: strength radius: radius
    ^ self ffiCall: #(void wavesim_inject(float x, float y, float strength, float radius))' classified: 'ffi'!

WaveSimFFI class compile: 'wavesimRenderToDisplayX: x y: y width: w height: h
    ^ self ffiCall: #(void wavesim_render_to_display(int x, int y, int w, int h))' classified: 'ffi'!

WaveSimFFI class compile: 'wavesimSetSpeed: speed
    ^ self ffiCall: #(void wavesim_set_speed(float speed))' classified: 'ffi'!

WaveSimFFI class compile: 'wavesimSetDamping: damping
    ^ self ffiCall: #(void wavesim_set_damping(float damping))' classified: 'ffi'!

WaveSimFFI class compile: 'wavesimSetColorScheme: scheme
    ^ self ffiCall: #(void wavesim_set_color_scheme(int scheme))' classified: 'ffi'!

WaveSimFFI class compile: 'wavesimSetNormalScale: scale
    ^ self ffiCall: #(void wavesim_set_normal_scale(float scale))' classified: 'ffi'!

WaveSimFFI class compile: 'wavesimReset
    ^ self ffiCall: #(void wavesim_reset(void))' classified: 'ffi'!

WaveSimFFI class compile: 'wavesimIsInitialized
    ^ self ffiCall: #(int wavesim_is_initialized(void))' classified: 'ffi'!

WaveSimFFI class compile: 'wavesimGridWidth
    ^ self ffiCall: #(int wavesim_grid_width(void))' classified: 'ffi'!

WaveSimFFI class compile: 'wavesimGridHeight
    ^ self ffiCall: #(int wavesim_grid_height(void))' classified: 'ffi'!

"======== Wave Simulation Morph (canvas) ========"!

Morph subclass: #WaveSimMorph
    instanceVariableNames: 'gridWidth gridHeight speed damping colorScheme normalScale sourceStrength sourceRadius stepsPerFrame running'
    classVariableNames: ''
    package: 'WaveSim'!

WaveSimMorph compile: 'initialize
    super initialize.
    gridWidth := 512.
    gridHeight := 384.
    speed := 0.15.
    damping := 0.005.
    colorScheme := 0.
    normalScale := 8.0.
    sourceStrength := 1.5.
    sourceRadius := 10.0.
    stepsPerFrame := 3.
    running := true.
    self color: Color transparent.
    self extent: 800@600' classified: 'initialization'!

WaveSimMorph compile: 'ensureInitialized
    WaveSimFFI wavesimIsInitialized = 0
        ifTrue: [
            WaveSimFFI wavesimInit: gridWidth height: gridHeight.
            WaveSimFFI wavesimSetSpeed: speed.
            WaveSimFFI wavesimSetDamping: damping.
            WaveSimFFI wavesimSetColorScheme: colorScheme.
            WaveSimFFI wavesimSetNormalScale: normalScale ]' classified: 'initialization'!

WaveSimMorph compile: 'renderToDisplay
    WaveSimFFI wavesimRenderToDisplayX: self bounds left asInteger
                                     y: self bounds top asInteger
                                 width: self bounds width asInteger
                                height: self bounds height asInteger' classified: 'rendering'!

WaveSimMorph compile: 'wantsSteps
    ^ true' classified: 'stepping'!

WaveSimMorph compile: 'stepTime
    ^ 33' classified: 'stepping'!

WaveSimMorph compile: 'step
    "Advance sim and render directly to display buffer.
     Do NOT call self changed — bypass Morphic redraw to avoid flicker."
    running ifFalse: [ ^ self ].
    self ensureInitialized.
    WaveSimFFI wavesimStep: stepsPerFrame.
    self renderToDisplay' classified: 'stepping'!

WaveSimMorph compile: 'drawOn: aCanvas
    "Called by Morphic when area needs explicit redraw (initial paint, overlap).
     Re-render current wave state to ensure display buffer is up to date."
    self ensureInitialized.
    self renderToDisplay' classified: 'drawing'!

WaveSimMorph compile: 'handlesMouseDown: evt
    ^ true' classified: 'events'!

WaveSimMorph compile: 'mouseDown: anEvent
    self injectWaveAt: anEvent position.
    anEvent hand newMouseFocus: self event: anEvent' classified: 'events'!

WaveSimMorph compile: 'mouseMove: anEvent
    anEvent anyButtonPressed ifTrue: [
        self injectWaveAt: anEvent position ]' classified: 'events'!

WaveSimMorph compile: 'mouseUp: anEvent
    "Release"' classified: 'events'!

WaveSimMorph compile: 'injectWaveAt: aPoint
    | local gx gy |
    self ensureInitialized.
    local := aPoint - self bounds origin.
    gx := (local x / self bounds width * gridWidth) asFloat.
    gy := (local y / self bounds height * gridHeight) asFloat.
    (gx between: 0.0 and: gridWidth asFloat) ifTrue: [
        (gy between: 0.0 and: gridHeight asFloat) ifTrue: [
            WaveSimFFI wavesimInjectX: gx y: gy
                            strength: sourceStrength
                              radius: sourceRadius ] ]' classified: 'simulation'!

WaveSimMorph compile: 'speed: aFloat
    speed := aFloat.
    WaveSimFFI wavesimSetSpeed: speed' classified: 'accessing'!

WaveSimMorph compile: 'damping: aFloat
    damping := aFloat.
    WaveSimFFI wavesimSetDamping: damping' classified: 'accessing'!

WaveSimMorph compile: 'colorScheme: anInt
    colorScheme := anInt.
    WaveSimFFI wavesimSetColorScheme: colorScheme' classified: 'accessing'!

WaveSimMorph compile: 'normalScale: aFloat
    normalScale := aFloat.
    WaveSimFFI wavesimSetNormalScale: normalScale' classified: 'accessing'!

WaveSimMorph compile: 'sourceStrength: aFloat
    sourceStrength := aFloat' classified: 'accessing'!

WaveSimMorph compile: 'sourceRadius: aFloat
    sourceRadius := aFloat' classified: 'accessing'!

WaveSimMorph compile: 'stepsPerFrame: anInt
    stepsPerFrame := anInt' classified: 'accessing'!

WaveSimMorph compile: 'running
    ^ running' classified: 'accessing'!

WaveSimMorph compile: 'toggleRunning
    running := running not' classified: 'accessing'!

WaveSimMorph compile: 'resetSimulation
    WaveSimFFI wavesimReset' classified: 'simulation'!

WaveSimMorph compile: 'speed ^ speed' classified: 'accessing'!
WaveSimMorph compile: 'damping ^ damping' classified: 'accessing'!
WaveSimMorph compile: 'colorScheme ^ colorScheme' classified: 'accessing'!
WaveSimMorph compile: 'normalScale ^ normalScale' classified: 'accessing'!
WaveSimMorph compile: 'sourceStrength ^ sourceStrength' classified: 'accessing'!
WaveSimMorph compile: 'sourceRadius ^ sourceRadius' classified: 'accessing'!
WaveSimMorph compile: 'stepsPerFrame ^ stepsPerFrame' classified: 'accessing'!

"======== Window Launcher ========"!

WaveSimMorph class compile: 'open
    ^ self openExtent: 800@600' classified: 'instance creation'!

WaveSimMorph class compile: 'openExtent: anExtent
    | window waveMorph |
    waveMorph := self new.
    waveMorph extent: anExtent.
    window := SystemWindow new.
    window setLabel: ''Wave Simulation (Metal GPU)''.
    window extent: anExtent + (0@30).
    window addMorph: waveMorph fullFrame: LayoutFrame identity.
    window openInWorld.
    ^ window' classified: 'instance creation'!

Stdio stderr nextPutAll: '[wavesim] WaveSim classes loaded'; lf; flush!

"Auto-open — click on the canvas to create waves!"
[
    WaveSimMorph open.
    "Initial demo wave"
    [
        (Delay forMilliseconds: 1500) wait.
        WaveSimFFI wavesimInjectX: 256.0 y: 192.0 strength: 2.0 radius: 12.0.
    ] fork.
] on: Error do: [ :e |
    Stdio stderr nextPutAll: '[wavesim] ERROR: '; nextPutAll: e messageText; lf; flush ]!
