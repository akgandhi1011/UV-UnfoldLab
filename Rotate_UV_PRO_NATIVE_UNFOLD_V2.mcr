/*
    Rotate UV
    Category : TEST
    Created by: akg_ai
    Pro rebuild based on UV_RotateTool.ms

    Main changes:
    - Safer local state / no leaked working globals
    - Reliable capture reset in Auto and Manual modes
    - Single undo transaction per command
    - Restores captured UV edge selection after operations
    - Auto-detects an Unwrap UVW modifier on a single selected object
    - Validates captured modifier / object state before use
    - Angle Snap is safely suspended/restored on 3ds Max 2026+
    - No blind Angle Snap toggle on older versions
    - Independent island rotation
    - Automatic rotation centers: island center for Auto, edge center for Manual
    - Topology + Edge-Flow Atlas V8: swept strips, cap loops, structural rails + V7.2 fallback
    - Unfold3D uses explicit Peel seams; no seam = no destructive solve
    - Pro quad-grid Straighten UV / Straighten Shell
    - Rotation presets and custom angle
    - Auto compact-fit Horizontal / Vertical alignment using true UV connected components
    - Manual selected-edge Horizontal / Vertical alignment
    - Max-style Arrange Elements UI using native EditUVW icons
    - Horizontal row / Vertical column UV island arrangement
    - Compact Block H/V with optional Rotate, Rescale and Fill Gaps
    - One-click Rescale Elements using Unwrap UVW RescaleCluster
    - Exact bounding-box padding in UV units; preserves scale unless Rescale is enabled
    - Status feedback and compact Help
*/

global RotateUV_Open
global RotateUV_FindUVEditorHWND

-- Find the floating Unwrap UV editor so Rotate UV can stay above it.
fn RotateUV_FindUVEditorHWND =
(
    local foundHWND = undefined
    local roots = #(0, windows.getMAXHWND())

    for root in roots while foundHWND == undefined do
    (
        local wins = try(windows.getChildrenHWND root)catch(#())
        for w in wins while foundHWND == undefined do
        (
            if w != undefined and w.count >= 5 do
            (
                local titleText = try(w[5] as string)catch("")
                if (matchPattern titleText pattern:"*Edit UVW*" ignoreCase:true) or
                   (matchPattern titleText pattern:"*UV Editor*" ignoreCase:true) or
                   (matchPattern titleText pattern:"*Unwrap UVW*" ignoreCase:true) do
                (
                    foundHWND = w[1]
                )
            )
        )
    )

    foundHWND
)

fn RotateUV_Open =
(
    global rol_RotateUV
    try(destroyDialog rol_RotateUV)catch()

    rollout rol_RotateUV "Rotate UV"
    (
        local uv = undefined
        local capturedNode = undefined
        local capturedEdges = #{}
        local referenceEdges = #()
        local capturedTopologyIslands = #()
        local capturedSelectionData = undefined
        local capturedMode = 1
        local isBusy = false
        local seamSuggestedUVEdges = #{}
        local seamAnalysisValid = false
        local seamAnalysisNode = undefined
        local seamAnalysisFaceCount = 0
        local seamTargetFaces = #{}
        local seamTubeCount = 0
        local seamManualCount = 0
        local atlasChartCount = 0
        local atlasWorstEnergy = 0.0

        ----------------------------------------------------------------------
        -- UI - extra compact Pro layout
        ----------------------------------------------------------------------
        groupBox grp_mode "MODE" pos:[6,5] width:292 height:60
        radioButtons rb_workMode "" labels:#("Auto - Compact Fit", "Manual - Selected Edge") default:1 columns:2 pos:[14,20]
        checkButton chk_capture "CAPTURE ISLANDS" pos:[101,42] width:102 height:18 highlightColor:(color 55 150 70) tooltip:"Capture the current UV shell scope for repeated rotation commands."
        button btn_help "?" pos:[273,42] width:18 height:18 tooltip:"About / Help"

        -- ALIGN and ROTATE share one compact row.
        groupBox grp_align "ALIGN" pos:[6,70] width:58 height:90
        button btn_alignHoriz "" pos:[17,88] width:34 height:28 iconName:@"UVWUnwrapDialog\AlignHorizontal" iconSize:[22,22] tooltip:"Align Horizontal - Auto finds the most compact orientation for each target shell. Manual uses the selected reference edge."
        button btn_alignVert "" pos:[17,124] width:34 height:28 iconName:@"UVWUnwrapDialog\AlignVertical" iconSize:[22,22] tooltip:"Align Vertical - Auto finds the most compact orientation for each target shell. Manual uses the selected reference edge."

        groupBox grp_presets "ROTATE" pos:[69,70] width:229 height:90
        button btn_m90 "" pos:[79,88] width:34 height:28 iconName:@"UVWUnwrapDialog\Rotate-90" iconSize:[21,21] tooltip:"Rotate captured shells -90 degrees."
        button btn_m45 "-45" pos:[119,88] width:34 height:28 tooltip:"Rotate captured shells -45 degrees."
        button btn_p45 "+45" pos:[159,88] width:34 height:28 tooltip:"Rotate captured shells +45 degrees."
        button btn_p90 "" pos:[199,88] width:34 height:28 iconName:@"UVWUnwrapDialog\Rotate90" iconSize:[21,21] tooltip:"Rotate captured shells +90 degrees."
        button btn_180 "180" pos:[239,88] width:40 height:28 tooltip:"Rotate captured shells 180 degrees."

        spinner spn_angle "Custom Angle:" pos:[79,124] width:120 fieldWidth:48 range:[0.0,360.0,15.0] type:#float scale:1.0
        button btn_ccw "CCW" pos:[207,121] width:35 height:23 tooltip:"Rotate counter-clockwise by Custom Angle."
        button btn_cw "CW" pos:[247,121] width:32 height:23 tooltip:"Rotate clockwise by Custom Angle."

        groupBox grp_arrange "ARRANGE ELEMENTS" pos:[6,165] width:292 height:108

        -- Native 3ds Max UV icons: theme-aware and DPI-aware.
        button btn_arrangeHoriz "" pos:[17,184] width:34 height:31 iconName:@"EditUVW\SpaceHorizontally" iconSize:[23,23] tooltip:"Horizontal Row - arrange target shells left-to-right."
        button btn_arrangeVert "" pos:[72,184] width:34 height:31 iconName:@"EditUVW\SpaceVertically" iconSize:[23,23] tooltip:"Vertical Column - arrange target shells top-to-bottom."
        button btn_compactH "" pos:[127,184] width:34 height:31 iconName:@"EditUVW\PackTogether" iconSize:[23,23] tooltip:"Compact Block H - landscape-biased compact block."
        button btn_compactV "" pos:[182,184] width:34 height:31 iconName:@"EditUVW\PackCustom" iconSize:[23,23] tooltip:"Compact Block V - portrait-biased compact block."
        button btn_rescaleNow "" pos:[237,184] width:34 height:31 iconName:@"EditUVW\RescaleElements" iconSize:[23,23] tooltip:"Rescale Elements now - normalize relative cluster scale for target shells."

        checkbox cb_arrRotate "Rotate" pos:[14,224] width:56 height:18 checked:true tooltip:"Compact-orient each target shell before arrangement."
        checkbox cb_arrRescale "Rescale" pos:[73,224] width:60 height:18 checked:false tooltip:"Normalize relative cluster scale before arrangement. OFF preserves current texel scale."
        checkbox cb_fillGaps "Fill Gaps" pos:[136,224] width:68 height:18 checked:true tooltip:"Compact Block only: use smaller/thinner shells to fill available free spaces."
        spinner spn_spacing "Padding:" pos:[205,222] width:84 fieldWidth:40 range:[0.0,100.0,0.01] type:#float scale:0.001 tooltip:"Exact UV-space gap between arranged shell bounding boxes."
        label lbl_arrangeScope "Selected shells only   |   No selection = all shells" pos:[14,249] width:276 height:15 align:#center

        -- SEAM / UNFOLD / STRAIGHTEN - explicit seam-first workflow.
        groupBox grp_unfold "SEAM / UNFOLD / STRAIGHTEN" pos:[6,278] width:292 height:91

        -- Row 1: native seam optimization. Generate never changes the Max mesh/UV topology.
        button btn_seamAnalyze "" pos:[14,292] width:34 height:29 iconName:@"EditUVW\FlattenByPolygonAngle" iconSize:[22,22] tooltip:"Generate Native Auto Seam - Feature-Aware planner detects structural loops, caps, transitions and controlled longitudinal openings. This only prepares a seam proposal."
        button btn_seamPreview "" pos:[54,292] width:34 height:29 iconName:@"EditUVW\EditSeams" iconSize:[22,22] tooltip:"Preview Native Auto Seam - selects the proposed internal seam edges on the current Max mesh. Open mesh borders are not proposed."
        button btn_seamApply "" pos:[94,292] width:34 height:29 iconName:@"EditUVW\ConvertEdgeToSeams" iconSize:[22,22] tooltip:"Apply Native Auto Seam - converts the previewed edge selection to Peel/Pelt seams. Existing seams are preserved."
        dropdownlist ddl_autoSeamProfile "" pos:[136,295] width:152 height:21 items:#("Minimal Seams","Balanced","Low Distortion","Ideal Standard") selection:4 tooltip:"Ideal Standard: topology-first seams for Box, ChamferBox, Cylinder/Tube and Torus, with Feature-Aware fallback for arbitrary meshes."

        -- Row 2: solve and finishing tools.
        button btn_unfold "" pos:[18,329] width:34 height:31 iconName:@"EditUVW\QuickPeel" iconSize:[23,23] tooltip:"Native Unfold V2 - libigl LSCM initialization + SLIM symmetric-Dirichlet optimization for seam-constrained shells. Requires applied Peel/Pelt seams. Falls back to 3ds Max Unfold3D if the native worker is unavailable."
        button btn_optimize "" pos:[58,329] width:34 height:31 iconName:@"EditUVW\RelaxUntilFlat" iconSize:[23,23] tooltip:"Optimize - gentle Unfold3D relaxation. It never creates or changes seams."
        button btn_straightenUV "" pos:[98,329] width:34 height:31 iconName:@"EditUVW\StraightenSelection" iconSize:[23,23] tooltip:"Straighten UV - rectangularize selected quad-grid UV patches. Preserves patch center and 3D-proportional row/column spacing."
        button btn_straightenShell "" pos:[138,329] width:34 height:31 iconName:@"MainUI\Shell" iconSize:[23,23] tooltip:"Straighten Shell - promote selection to complete shells and rectangularize each valid quad-grid shell independently."
        label lbl_unfoldScope "Seams -> Native Unfold" pos:[176,336] width:112 height:16 align:#center tooltip:"Recommended workflow: Generate -> Preview -> Apply -> Native Unfold. Existing seam generation, Align, Rotate, Arrange and Straighten are unchanged."

        -- Slim footer: status left, creator credit right.
        label lbl_status "Ready." pos:[7,375] width:190 height:17
        dotNetControl lbl_credit "System.Windows.Forms.Label" pos:[203,375] width:96 height:17

        ----------------------------------------------------------------------
        -- Helpers
        ----------------------------------------------------------------------
        fn setStatus txt =
        (
            lbl_status.text = txt
        )

        fn clearCapture updateButton:true =
        (
            capturedNode = undefined
            capturedEdges = #{}
            referenceEdges = #()
            capturedTopologyIslands = #()
            capturedSelectionData = undefined
            capturedMode = rb_workMode.state
            if updateButton do chk_capture.state = false
            chk_capture.text = "CAPTURE ISLANDS"
        )

        fn firstBit ba =
        (
            local a = ba as array
            if a.count > 0 then a[1] else undefined
        )

        fn resolveUnwrap =
        (
            local currentMod = undefined
            local found = undefined

            try(currentMod = modPanel.getCurrentObject())catch(currentMod = undefined)
            if currentMod != undefined and (classOf currentMod == Unwrap_UVW) then
            (
                found = currentMod
            )
            else if selection.count == 1 then
            (
                for m in selection[1].modifiers while found == undefined do
                (
                    if classOf m == Unwrap_UVW do found = m
                )

                if found != undefined do
                (
                    try(max modify mode)catch()
                    try(modPanel.setCurrentObject found)catch()
                )
            )
            found
        )

        fn ensureUnwrapReady =
        (
            if uv == undefined do uv = resolveUnwrap()
            if uv == undefined then
            (
                setStatus "No Unwrap UVW modifier found."
                messageBox "Select one object with an Unwrap UVW modifier, then try again." title:"Rotate UV"
                false
            )
            else
            (
                local currentMod = undefined
                try(currentMod = modPanel.getCurrentObject())catch(currentMod = undefined)
                if currentMod != uv do
                (
                    try(max modify mode)catch()
                    try(modPanel.setCurrentObject uv)catch()
                )
                true
            )
        )

        fn captureStillValid =
        (
            if not chk_capture.state then
            (
                setStatus "Capture UV islands first."
                false
            )
            else if uv == undefined then
            (
                setStatus "Capture is empty - capture again."
                clearCapture()
                false
            )
            else if capturedMode == 1 and capturedTopologyIslands.count == 0 then
            (
                setStatus "Auto capture is empty - capture again."
                clearCapture()
                false
            )
            else if capturedMode == 2 and referenceEdges.count == 0 then
            (
                setStatus "Manual capture is empty - capture again."
                clearCapture()
                false
            )
            else if capturedNode != undefined and not isValidNode capturedNode then
            (
                setStatus "Captured object is no longer valid."
                clearCapture()
                false
            )
            else
            (
                local currentMod = undefined
                try(currentMod = modPanel.getCurrentObject())catch(currentMod = undefined)
                if currentMod != uv then
                (
                    setStatus "Modifier changed - Capture Islands again."
                    false
                )
                else true
            )
        )

        fn getEdgeVerts edgeBA =
        (
            local result = #()
            try
            (
                uv.selectEdges edgeBA
                uv.edgeToVertSelect()
                result = uv.getSelectedVertices() as array
            )
            catch(result = #())
            result
        )

        fn getEdgePoints edgeBA =
        (
            local verts = getEdgeVerts edgeBA
            if verts.count < 2 then undefined
            else
            (
                local p1 = undefined
                local p2 = undefined
                try
                (
                    p1 = uv.getVertexPosition 0 verts[1]
                    p2 = uv.getVertexPosition 0 verts[2]
                )
                catch
                (
                    p1 = undefined
                    p2 = undefined
                )
                if p1 == undefined or p2 == undefined then undefined else #(p1,p2)
            )
        )

        -- Manual operations use the selected/reference edge center.
        -- Auto topology operations use each island center (see topologyPivot).
        fn getPivot edgeBA =
        (
            local pts = getEdgePoints edgeBA
            if pts == undefined then undefined else ((pts[1] + pts[2]) / 2.0)
        )

        fn suspendAngleSnap =
        (
            local state = undefined
            try
            (
                if isProperty snapMode #angleSnapActive do
                (
                    state = snapMode.angleSnapActive
                    snapMode.angleSnapActive = false
                )
            )
            catch(state = undefined)
            state
        )

        fn restoreAngleSnap state =
        (
            if state != undefined do
            (
                try(snapMode.angleSnapActive = state)catch()
            )
        )

        fn rotateIsland edgeBA angleRad =
        (
            local pivot = getPivot edgeBA
            if pivot == undefined then false
            else
            (
                local snapState = suspendAngleSnap()
                local ok = true
                try
                (
                    uv.selectEdges edgeBA
                    uv.selectElement()
                    uv.RotateSelected angleRad [pivot.x,pivot.y,0]
                )
                catch(ok = false)
                restoreAngleSnap snapState
                ok
            )
        )

        fn normalizeAxisAngle a =
        (
            local n = a
            while n > 90.0 do n -= 180.0
            while n < -90.0 do n += 180.0
            n
        )

        fn alignIsland edgeBA axisMode =
        (
            local pts = getEdgePoints edgeBA
            if pts == undefined then false
            else
            (
                local p1 = pts[1]
                local p2 = pts[2]
                local dx = p2.x - p1.x
                local dy = p2.y - p1.y
                if (abs dx < 0.0000001 and abs dy < 0.0000001) then false
                else
                (
                    local currentAngle = atan2 dy dx
                    local correction = 0.0
                    if axisMode == #horizontal then
                    (
                        correction = -(normalizeAxisAngle currentAngle)
                    )
                    else
                    (
                        correction = -(normalizeAxisAngle (currentAngle - 90.0))
                    )
                    rotateIsland edgeBA (degToRad correction)
                )
            )
        )

        fn getIslandPoints edgeSet =
        (
            local points = #()
            try
            (
                uv.selectEdges edgeSet
                uv.edgeToVertSelect()
                local verts = uv.getSelectedVertices() as array
                for v in verts do append points (uv.getVertexPosition 0 v)
            )
            catch(points = #())
            points
        )

        fn compactBBoxScore points angleDeg =
        (
            if points.count < 2 then undefined
            else
            (
                local c = cos angleDeg
                local sn = sin angleDeg
                local minX = 1e30
                local minY = 1e30
                local maxX = -1e30
                local maxY = -1e30

                for p in points do
                (
                    local x = (p.x * c) - (p.y * sn)
                    local y = (p.x * sn) + (p.y * c)
                    if x < minX do minX = x
                    if x > maxX do maxX = x
                    if y < minY do minY = y
                    if y > maxY do maxY = y
                )

                local w = maxX - minX
                local h = maxY - minY
                local area = w * h
                local maxDim = if w > h then w else h
                #(area, maxDim, w, h)
            )
        )

        fn bestCompactEdge islandEdges axisMode =
        (
            local islandPoints = getIslandPoints islandEdges
            if islandPoints.count < 2 then undefined
            else
            (
                local bestEdge = undefined
                local bestCorrection = 0.0
                local bestArea = 1e30
                local bestMaxDim = 1e30
                local bestLength = -1.0
                local bestTurn = 1e30
                local testedAngles = #()

                for edgeID in (islandEdges as array) do
                (
                    local edgeBA = #{edgeID}
                    local pts = getEdgePoints edgeBA
                    if pts != undefined do
                    (
                        local dx = pts[2].x - pts[1].x
                        local dy = pts[2].y - pts[1].y
                        local edgeLen = sqrt((dx*dx) + (dy*dy))
                        if edgeLen > 0.0000001 do
                        (
                            local edgeAngle = atan2 dy dx
                            local baseCorrection = -(normalizeAxisAngle edgeAngle)
                            local correction = if axisMode == #horizontal then baseCorrection else (baseCorrection + 90.0)

                            -- Parallel / near-parallel edges lead to the same compact test.
                            -- Quantize to 0.25 degree so dense shells do not repeat work.
                            local canonical = normalizeAxisAngle baseCorrection
                            local key = (floor((canonical / 0.25) + 0.5)) as integer

                            if (findItem testedAngles key) == 0 do
                            (
                                append testedAngles key
                                local score = compactBBoxScore islandPoints correction
                                if score != undefined do
                                (
                                    local area = score[1]
                                    local maxDim = score[2]
                                    local turn = abs(normalizeAxisAngle correction)
                                    local eps = 0.00000001

                                    local better = false
                                    if area < (bestArea - eps) then
                                        better = true
                                    else if abs(area - bestArea) <= eps then
                                    (
                                        if maxDim < (bestMaxDim - eps) then
                                            better = true
                                        else if abs(maxDim - bestMaxDim) <= eps then
                                        (
                                            if edgeLen > (bestLength + eps) then
                                                better = true
                                            else if abs(edgeLen - bestLength) <= eps and turn < bestTurn do
                                                better = true
                                        )
                                    )

                                    if better do
                                    (
                                        bestArea = area
                                        bestMaxDim = maxDim
                                        bestLength = edgeLen
                                        bestTurn = turn
                                        bestEdge = edgeBA
                                        bestCorrection = correction
                                    )
                                )
                            )
                        )
                    )
                )

                if bestEdge == undefined then undefined else #(bestEdge, bestCorrection, bestArea)
            )
        )

        fn buildIslandEdgeSets selectedEdges =
        (
            local islands = #()
            local remaining = copy selectedEdges
            local safety = 0

            while not remaining.isEmpty and safety < 100000 do
            (
                safety += 1
                local seedID = firstBit remaining
                if seedID == undefined then
                    remaining = #{}
                else
                (
                    local seedBA = #{seedID}
                    local islandEdges = undefined
                    try
                    (
                        uv.selectEdges seedBA
                        uv.selectElement()
                        islandEdges = uv.getSelectedEdges()
                    )
                    catch(islandEdges = undefined)

                    if islandEdges == undefined or islandEdges.isEmpty then
                        remaining[seedID] = false
                    else
                    (
                        append islands (copy islandEdges)
                        remaining = remaining - islandEdges
                    )
                )
            )
            islands
        )

        fn alignIslandCompact islandEdges axisMode =
        (
            local best = bestCompactEdge islandEdges axisMode
            if best == undefined then false
            else rotateIsland best[1] (degToRad best[2])
        )

        fn longestEdgeFrom edgeSet =
        (
            local edgeArray = edgeSet as array
            local bestID = undefined
            local bestLength = -1.0

            for edgeID in edgeArray do
            (
                local edgeBA = #{edgeID}
                local pts = getEdgePoints edgeBA
                if pts != undefined do
                (
                    local d = distance pts[1] pts[2]
                    if d > bestLength do
                    (
                        bestLength = d
                        bestID = edgeID
                    )
                )
            )

            if bestID == undefined then undefined else #{bestID}
        )

        fn buildReferenceEdges mode =
        (
            referenceEdges = #()
            local originalSelection = undefined
            try(originalSelection = uv.getSelectedEdges())catch(originalSelection = undefined)

            if originalSelection == undefined or originalSelection.isEmpty then false
            else
            (
                capturedEdges = copy originalSelection
                local remainingSeeds = copy originalSelection
                local failed = false

                while not remainingSeeds.isEmpty and not failed do
                (
                    local seedID = firstBit remainingSeeds
                    if seedID == undefined then
                    (
                        failed = true
                    )
                    else
                    (
                        local seedBA = #{seedID}
                        local islandEdges = undefined
                        try
                        (
                            uv.selectEdges seedBA
                            uv.selectElement()
                            islandEdges = uv.getSelectedEdges()
                        )
                        catch(islandEdges = undefined)

                        if islandEdges == undefined or islandEdges.isEmpty then
                        (
                            failed = true
                        )
                        else
                        (
                            local ref = undefined
                            if mode == 1 then
                                ref = longestEdgeFrom islandEdges
                            else
                                ref = seedBA

                            if ref != undefined do append referenceEdges ref
                            remainingSeeds = remainingSeeds - islandEdges
                        )
                    )
                )

                try(uv.selectEdges capturedEdges)catch()
                (referenceEdges.count > 0 and not failed)
            )
        )

        fn buildDirectReferenceEdges selectedEdges =
        (
            local directRefs = #()
            local remaining = copy selectedEdges
            local safety = 0

            while not remaining.isEmpty and safety < 100000 do
            (
                safety += 1
                local seedID = firstBit remaining
                if seedID == undefined then
                (
                    remaining = #{}
                )
                else
                (
                    local seedBA = #{seedID}
                    local islandEdges = undefined
                    try
                    (
                        uv.selectEdges seedBA
                        uv.selectElement()
                        islandEdges = uv.getSelectedEdges()
                    )
                    catch(islandEdges = undefined)

                    if islandEdges == undefined or islandEdges.isEmpty then
                    (
                        remaining[seedID] = false
                    )
                    else
                    (
                        append directRefs seedBA
                        remaining = remaining - islandEdges
                    )
                )
            )
            directRefs
        )


        fn getCurrentSelectionAsVertices =
        (
            /*
                ACTIVE UV SELECTION RULE
                ------------------------
                The ACTIVE UV sub-object mode defines the processing set.
                This prevents stale selections stored in the other UV modes from
                unexpectedly pulling unrelated shells into Auto Align/Arrange.

                Vertex mode -> selected TV vertices
                Edge mode   -> vertices touched by selected UV edges
                Face mode   -> vertices touched by selected UV faces/elements

                The original selections in all modes are restored afterwards.
                If seedVerts is empty, callers may deliberately fall back to ALL
                UV shells.
            */
            local subMode = 0
            local savedVerts = #{}
            local savedEdges = #{}
            local savedFaces = #{}
            local seedVerts = #{}
            local tempVerts = #{}

            try(subMode = uv.getTVSubObjectMode())catch(subMode = 0)
            try(savedVerts = copy (uv.getSelectedVertices()))catch(savedVerts = #{})
            try(savedEdges = copy (uv.getSelectedEdges()))catch(savedEdges = #{})
            try(savedFaces = copy (uv.getSelectedFaces()))catch(savedFaces = #{})

            case subMode of
            (
                1:
                (
                    seedVerts = copy savedVerts
                )
                2:
                (
                    if not savedEdges.isEmpty do
                    (
                        try
                        (
                            uv.setTVSubObjectMode 2
                            uv.selectEdges savedEdges
                            uv.edgeToVertSelect()
                            tempVerts = copy (uv.getSelectedVertices())
                            seedVerts = copy tempVerts
                        )
                        catch(seedVerts = #{})
                    )
                )
                3:
                (
                    if not savedFaces.isEmpty do
                    (
                        try
                        (
                            uv.setTVSubObjectMode 3
                            uv.selectFaces savedFaces
                            uv.faceToVertSelect()
                            tempVerts = copy (uv.getSelectedVertices())
                            seedVerts = copy tempVerts
                        )
                        catch(seedVerts = #{})
                    )
                )
                default:
                (
                    seedVerts = #{}
                )
            )

            try
            (
                uv.setTVSubObjectMode 1
                uv.selectVertices savedVerts
                uv.setTVSubObjectMode 2
                uv.selectEdges savedEdges
                uv.setTVSubObjectMode 3
                uv.selectFaces savedFaces
                if subMode >= 1 and subMode <= 3 do uv.setTVSubObjectMode subMode
            )
            catch()

            #(subMode, savedVerts, savedEdges, savedFaces, seedVerts)
        )

        fn restoreUVSelection selectionData =
        (
            if selectionData == undefined or selectionData.count < 5 then false
            else
            (
                local subMode = selectionData[1]
                local ok = true
                try
                (
                    uv.setTVSubObjectMode 1
                    uv.selectVertices selectionData[2]
                    uv.setTVSubObjectMode 2
                    uv.selectEdges selectionData[3]
                    uv.setTVSubObjectMode 3
                    uv.selectFaces selectionData[4]
                    if subMode >= 1 and subMode <= 3 do uv.setTVSubObjectMode subMode
                )
                catch(ok = false)
                ok
            )
        )

        /*
            Build ALL true UV shells from the active Unwrap topology.

            IMPORTANT:
            A packing shell is connected through SHARED UV EDGES, not merely
            through a shared TV vertex.  Vertex-only contact must NOT merge two
            shells, otherwise many visually separate pieces become one giant
            component and rotate together.

            Returned island format:
                #( islandVertexBitArray, boundaryEdgePairsArray )

            boundaryEdgePairsArray entries are #(tvVertA, tvVertB).
            Only boundary edges are kept because a minimum-area axis-aligned
            orientation is always represented by an outer-boundary direction;
            internal triangulation edges should not drive packing orientation.
        */

        fn uvEdgeRecordCompare a b =
        (
            if a[1] < b[1] then -1
            else if a[1] > b[1] then 1
            else if a[2] < b[2] then -1
            else if a[2] > b[2] then 1
            else if a[3] < b[3] then -1
            else if a[3] > b[3] then 1
            else 0
        )

        fn buildAllUVIslands =
        (
            local islands = #()
            local numVerts = 0
            local numFaces = 0
            try(numVerts = uv.NumberVertices())catch(numVerts = 0)
            try(numFaces = uv.numberPolygons())catch(numFaces = 0)

            if numVerts < 1 or numFaces < 1 then return islands

            local faceVerts = for f = 1 to numFaces collect #()
            local faceAdj = for f = 1 to numFaces collect #{}
            local boundaryByFace = for f = 1 to numFaces collect #()
            local edgeRecords = #()

            -- Read texture-face topology and make canonical UV edge records:
            -- #(minTV, maxTV, faceIndex).
            for f = 1 to numFaces do
            (
                local nPts = 0
                try(nPts = uv.numberPointsInFace f)catch(nPts = 0)

                if nPts > 1 do
                (
                    local fv = #()
                    for k = 1 to nPts do
                    (
                        local tv = 0
                        try(tv = uv.getVertexIndexFromFace f k)catch(tv = 0)
                        append fv tv
                    )
                    faceVerts[f] = fv

                    for k = 1 to fv.count do
                    (
                        local a = fv[k]
                        local b = fv[if k == fv.count then 1 else k + 1]
                        if a >= 1 and b >= 1 and a <= numVerts and b <= numVerts and a != b do
                        (
                            local lo = if a < b then a else b
                            local hi = if a < b then b else a
                            append edgeRecords #(lo, hi, f)
                        )
                    )
                )
            )

            if edgeRecords.count < 1 then return islands

            qsort edgeRecords uvEdgeRecordCompare

            -- Faces are adjacent ONLY when they share the same complete UV edge.
            -- An edge occurring once is a shell boundary candidate.
            local i = 1
            while i <= edgeRecords.count do
            (
                local lo = edgeRecords[i][1]
                local hi = edgeRecords[i][2]
                local firstFace = edgeRecords[i][3]
                local j = i + 1

                while j <= edgeRecords.count and edgeRecords[j][1] == lo and edgeRecords[j][2] == hi do
                    j += 1

                local groupCount = j - i
                if groupCount == 1 then
                (
                    append boundaryByFace[firstFace] #(lo, hi)
                )
                else
                (
                    -- Connect every face in this edge group to the first face.
                    -- This also behaves sensibly for rare non-manifold UV edges.
                    local r = i + 1
                    while r < j do
                    (
                        local otherFace = edgeRecords[r][3]
                        if otherFace != firstFace do
                        (
                            faceAdj[firstFace][otherFace] = true
                            faceAdj[otherFace][firstFace] = true
                        )
                        r += 1
                    )
                )

                i = j
            )

            -- Flood-fill FACE components.  This is the key difference from the
            -- previous version: touching at only one UV vertex does not connect.
            local visitedFaces = #{}

            for startFace = 1 to numFaces do
            (
                if faceVerts[startFace].count > 1 and not visitedFaces[startFace] do
                (
                    local queue = #(startFace)
                    local qIndex = 1
                    local componentFaces = #{}
                    local islandVerts = #{}
                    local boundaryPairs = #()
                    visitedFaces[startFace] = true

                    while qIndex <= queue.count do
                    (
                        local f = queue[qIndex]
                        qIndex += 1
                        componentFaces[f] = true

                        for tv in faceVerts[f] do
                        (
                            if tv >= 1 and tv <= numVerts do islandVerts[tv] = true
                        )

                        for pair in boundaryByFace[f] do append boundaryPairs pair

                        for n in faceAdj[f] do
                        (
                            if not visitedFaces[n] do
                            (
                                visitedFaces[n] = true
                                append queue n
                            )
                        )
                    )

                    if not islandVerts.isEmpty do append islands #(islandVerts, boundaryPairs, componentFaces)
                )
            )

            islands
        )

        fn filterTopologyIslandsBySelection allIslands selectionData =
        (
            /*
                If the active UV mode has a selection, return only complete UV
                shells touched by that selection.  A partial face/edge/vertex
                selection therefore promotes to its complete UV shell.

                If there is no active UV selection, return all shells so Auto can
                still be used globally.
            */
            if allIslands == undefined then return #()
            if selectionData == undefined or selectionData.count < 5 then return allIslands

            local seedVerts = selectionData[5]
            if seedVerts == undefined or seedVerts.isEmpty then return allIslands

            local filtered = #()
            for islandData in allIslands do
            (
                if islandData != undefined and islandData.count >= 1 do
                (
                    local islandVerts = islandData[1]
                    local hit = false
                    if islandVerts != undefined do
                    (
                        for v in seedVerts while not hit do
                        (
                            if islandVerts[v] do hit = true
                        )
                    )
                    if hit do append filtered islandData
                )
            )
            filtered
        )

        fn selectionScopeLabel selectionData =
        (
            if selectionData != undefined and selectionData.count >= 5 and selectionData[5] != undefined and not selectionData[5].isEmpty then
                "selected"
            else
                "all"
        )

        fn getPointsFromVerts vertBA =
        (
            local points = #()
            if vertBA != undefined do
            (
                for v in vertBA do
                (
                    local p = undefined
                    try(p = uv.getVertexPosition 0 v)catch(p = undefined)
                    if p != undefined do append points p
                )
            )
            points
        )

        fn centerFromVerts vertBA =
        (
            local pts = getPointsFromVerts vertBA
            if pts.count == 0 then undefined
            else
            (
                local c = [0.0,0.0,0.0]
                for p in pts do c += p
                c / pts.count
            )
        )

        fn bestCompactPair islandVerts edgePairs axisMode =
        (
            local islandPoints = getPointsFromVerts islandVerts
            if islandPoints.count < 2 or edgePairs.count < 1 then undefined
            else
            (
                local bestPair = undefined
                local bestCorrection = 0.0
                local bestArea = 1e30
                local bestMaxDim = 1e30
                local bestLength = -1.0
                local bestTurn = 1e30
                local testedAngles = #()

                for pair in edgePairs do
                (
                    if pair.count >= 2 do
                    (
                        local p1 = undefined
                        local p2 = undefined
                        try
                        (
                            p1 = uv.getVertexPosition 0 pair[1]
                            p2 = uv.getVertexPosition 0 pair[2]
                        )
                        catch
                        (
                            p1 = undefined
                            p2 = undefined
                        )

                        if p1 != undefined and p2 != undefined do
                        (
                            local dx = p2.x - p1.x
                            local dy = p2.y - p1.y
                            local edgeLen = sqrt((dx*dx) + (dy*dy))
                            if edgeLen > 0.0000001 do
                            (
                                local edgeAngle = atan2 dy dx
                                local baseCorrection = -(normalizeAxisAngle edgeAngle)
                                local correction = if axisMode == #horizontal then baseCorrection else (baseCorrection + 90.0)

                                local canonical = normalizeAxisAngle baseCorrection
                                local key = (floor((canonical / 0.25) + 0.5)) as integer

                                if (findItem testedAngles key) == 0 do
                                (
                                    append testedAngles key
                                    local score = compactBBoxScore islandPoints correction
                                    if score != undefined do
                                    (
                                        local area = score[1]
                                        local maxDim = score[2]
                                        local turn = abs(normalizeAxisAngle correction)
                                        local eps = 0.00000001
                                        local better = false

                                        if area < (bestArea - eps) then
                                            better = true
                                        else if abs(area - bestArea) <= eps then
                                        (
                                            if maxDim < (bestMaxDim - eps) then
                                                better = true
                                            else if abs(maxDim - bestMaxDim) <= eps then
                                            (
                                                if edgeLen > (bestLength + eps) then
                                                    better = true
                                                else if abs(edgeLen - bestLength) <= eps and turn < bestTurn do
                                                    better = true
                                            )
                                        )

                                        if better do
                                        (
                                            bestArea = area
                                            bestMaxDim = maxDim
                                            bestLength = edgeLen
                                            bestTurn = turn
                                            bestPair = pair
                                            bestCorrection = correction
                                        )
                                    )
                                )
                            )
                        )
                    )
                )

                if bestPair == undefined then undefined else #(bestPair, bestCorrection, bestArea)
            )
        )

        fn rotateIslandVerts islandVerts angleRad pivot =
        (
            if islandVerts == undefined or islandVerts.isEmpty or pivot == undefined then false
            else
            (
                local snapState = suspendAngleSnap()
                local ok = true
                try
                (
                    uv.selectVertices islandVerts
                    uv.RotateSelected angleRad [pivot.x,pivot.y,0]
                )
                catch(ok = false)
                restoreAngleSnap snapState
                ok
            )
        )

        fn alignTopologyIslandCompact islandData axisMode =
        (
            if islandData == undefined or islandData.count < 2 then false
            else
            (
                local islandVerts = islandData[1]
                local edgePairs = islandData[2]
                local best = bestCompactPair islandVerts edgePairs axisMode
                local pivot = centerFromVerts islandVerts

                if best == undefined or pivot == undefined then false
                else rotateIslandVerts islandVerts (degToRad best[2]) pivot
            )
        )

        fn bboxFromVerts vertBA =
        (
            if vertBA == undefined or vertBA.isEmpty then undefined
            else
            (
                local minX = 1e30
                local minY = 1e30
                local maxX = -1e30
                local maxY = -1e30
                local validCount = 0

                for v in vertBA do
                (
                    local p = undefined
                    try(p = uv.getVertexPosition 0 v)catch(p = undefined)
                    if p != undefined do
                    (
                        validCount += 1
                        if p.x < minX do minX = p.x
                        if p.x > maxX do maxX = p.x
                        if p.y < minY do minY = p.y
                        if p.y > maxY do maxY = p.y
                    )
                )

                if validCount < 1 then undefined
                else
                (
                    local w = maxX - minX
                    local h = maxY - minY
                    local cx = (minX + maxX) * 0.5
                    local cy = (minY + maxY) * 0.5
                    #(minX, minY, maxX, maxY, w, h, cx, cy)
                )
            )
        )

        fn buildArrangementItems topologyIslands =
        (
            local items = #()
            for islandData in topologyIslands do
            (
                if islandData != undefined and islandData.count >= 1 do
                (
                    local bb = bboxFromVerts islandData[1]
                    if bb != undefined do append items #(islandData, bb)
                )
            )
            items
        )


        fn arrangementGroupCenter items =
        (
            if items == undefined or items.count < 1 then undefined
            else
            (
                local minX = 1e30
                local minY = 1e30
                local maxX = -1e30
                local maxY = -1e30

                for item in items do
                (
                    local bb = item[2]
                    if bb[1] < minX do minX = bb[1]
                    if bb[2] < minY do minY = bb[2]
                    if bb[3] > maxX do maxX = bb[3]
                    if bb[4] > maxY do maxY = bb[4]
                )

                #((minX + maxX) * 0.5, (minY + maxY) * 0.5)
            )
        )

        fn topologyFaceSelection topologyIslands =
        (
            local faceSel = #{}
            if topologyIslands != undefined do
            (
                for islandData in topologyIslands do
                (
                    if islandData != undefined and islandData.count >= 3 do
                    (
                        for f in islandData[3] do faceSel[f] = true
                    )
                )
            )
            faceSel
        )

        fn activeUnwrapNode =
        (
            if selection.count == 1 then selection[1]
            else if capturedNode != undefined and isValidNode capturedNode then capturedNode
            else undefined
        )

        fn rescaleTopologyIslands topologyIslands =
        (
            local node = activeUnwrapNode()
            local faceSel = topologyFaceSelection topologyIslands
            if node == undefined or faceSel.isEmpty then false
            else
            (
                local ok = true
                try(uv.RescaleCluster faceSel node)catch(ok = false)
                ok
            )
        )

        fn rotateTopologyIslandsForArrange topologyIslands axisMode =
        (
            local rotated = 0
            if topologyIslands != undefined do
            (
                for islandData in topologyIslands do
                (
                    if alignTopologyIslandCompact islandData axisMode do rotated += 1
                )
            )
            rotated
        )

        fn rescaleCurrentIslands =
        (
            if isBusy then false
            else
            (
                isBusy = true
                uv = resolveUnwrap()
                local result = false

                if ensureUnwrapReady() then
                (
                    local selectionData = getCurrentSelectionAsVertices()
                    local allTopologyIslands = buildAllUVIslands()
                    local topologyIslands = filterTopologyIslandsBySelection allTopologyIslands selectionData
                    local totalCount = topologyIslands.count

                    if totalCount < 1 then
                    (
                        if selectionData != undefined do restoreUVSelection selectionData
                        setStatus "Rescale: no UV shells detected."
                    )
                    else
                    (
                        local oldElementMode = undefined
                        local oldLock = undefined
                        local ok = false
                        try(oldElementMode = uv.getTVElementMode())catch(oldElementMode = undefined)
                        try(oldLock = uv.getLock())catch(oldLock = undefined)

                        undo "Rescale UV Elements" on
                        (
                            try(uv.setTVElementMode false)catch()
                            try(uv.setLock false)catch()
                            ok = rescaleTopologyIslands topologyIslands
                            if oldLock != undefined do try(uv.setLock oldLock)catch()
                            if oldElementMode != undefined do try(uv.setTVElementMode oldElementMode)catch()
                            if selectionData != undefined do restoreUVSelection selectionData
                        )

                        try(uv.updateMap())catch()
                        try(uv.invalidateView())catch()
                        try(redrawViews())catch()

                        if ok then
                        (
                            local scopeLabel = selectionScopeLabel selectionData
                            setStatus ((totalCount as string) + " " + scopeLabel + " shells rescaled.")
                            result = true
                        )
                        else
                        (
                            messageBox "Rescale Elements could not be applied. Select one object with an active Unwrap UVW modifier and try again." title:"Rotate UV"
                            setStatus "Rescale Elements failed."
                        )
                    )
                )

                isBusy = false
                result
            )
        )

        fn sortArrangementItems items axisMode =
        (
            -- Stable insertion sort avoids MAXScript closure/comparator issues.
            local sorted = #()
            for item in items do
            (
                local key = if axisMode == #horizontal then item[2][7] else item[2][8]
                local inserted = false

                if sorted.count == 0 then
                (
                    append sorted item
                    inserted = true
                )
                else
                (
                    for i = 1 to sorted.count while not inserted do
                    (
                        local otherKey = if axisMode == #horizontal then sorted[i][2][7] else sorted[i][2][8]
                        local goesBefore = if axisMode == #horizontal then (key < otherKey) else (key > otherKey)
                        if goesBefore do
                        (
                            insertItem item sorted i
                            inserted = true
                        )
                    )
                )

                if not inserted do append sorted item
            )
            sorted
        )

        fn moveIslandVerts islandVerts offset =
        (
            if islandVerts == undefined or islandVerts.isEmpty then false
            else
            (
                local ok = true
                try
                (
                    uv.selectVertices islandVerts
                    uv.moveSelected [offset.x, offset.y, 0]
                )
                catch(ok = false)
                ok
            )
        )

        fn arrangeAllUVIslands axisMode =
        (
            if isBusy then false
            else
            (
                isBusy = true
                uv = resolveUnwrap()
                local result = false

                if ensureUnwrapReady() then
                (
                    local selectionData = getCurrentSelectionAsVertices()
                    local allTopologyIslands = buildAllUVIslands()
                    local topologyIslands = filterTopologyIslandsBySelection allTopologyIslands selectionData
                    local initialItems = buildArrangementItems topologyIslands
                    local totalCount = initialItems.count

                    if totalCount < 1 then
                    (
                        if selectionData != undefined do restoreUVSelection selectionData
                        messageBox "No valid UV shells could be detected in the active Unwrap." title:"Rotate UV"
                        setStatus "Arrange: no UV shells detected."
                    )
                    else
                    (
                        local originalCenter = arrangementGroupCenter initialItems
                        local gap = spn_spacing.value
                        local successCount = 0
                        local rescaleOK = true
                        local oldElementMode = undefined
                        local oldLock = undefined
                        try(oldElementMode = uv.getTVElementMode())catch(oldElementMode = undefined)
                        try(oldLock = uv.getLock())catch(oldLock = undefined)

                        undo "Arrange UV Islands" on
                        (
                            try(uv.setTVElementMode false)catch()
                            try(uv.setLock false)catch()
                            try(uv.setTVSubObjectMode 1)catch()

                            if cb_arrRescale.checked do rescaleOK = rescaleTopologyIslands topologyIslands
                            if cb_arrRotate.checked do rotateTopologyIslandsForArrange topologyIslands axisMode

                            local items = buildArrangementItems topologyIslands
                            local sortedItems = sortArrangementItems items axisMode
                            local totalSpan = 0.0
                            local groupCenterX = if originalCenter == undefined then 0.0 else originalCenter[1]
                            local groupCenterY = if originalCenter == undefined then 0.0 else originalCenter[2]

                            if axisMode == #horizontal then
                            (
                                for item in sortedItems do totalSpan += item[2][5]
                            )
                            else
                            (
                                for item in sortedItems do totalSpan += item[2][6]
                            )
                            if sortedItems.count > 1 do totalSpan += gap * (sortedItems.count - 1)

                            local cursor = if axisMode == #horizontal then (groupCenterX - totalSpan * 0.5) else (groupCenterY + totalSpan * 0.5)

                            for item in sortedItems do
                            (
                                local islandData = item[1]
                                local bb = item[2]
                                local targetX = bb[7]
                                local targetY = bb[8]

                                if axisMode == #horizontal then
                                (
                                    targetX = cursor + (bb[5] * 0.5)
                                    targetY = groupCenterY
                                    cursor += bb[5] + gap
                                )
                                else
                                (
                                    targetX = groupCenterX
                                    targetY = cursor - (bb[6] * 0.5)
                                    cursor -= bb[6] + gap
                                )

                                if moveIslandVerts islandData[1] [targetX - bb[7], targetY - bb[8], 0] do successCount += 1
                            )

                            if oldLock != undefined do try(uv.setLock oldLock)catch()
                            if oldElementMode != undefined do try(uv.setTVElementMode oldElementMode)catch()
                            if selectionData != undefined do restoreUVSelection selectionData
                        )

                        try(uv.updateMap())catch()
                        try(uv.invalidateView())catch()
                        try(redrawViews())catch()

                        local axisLabel = if axisMode == #horizontal then "Horizontal Row" else "Vertical Column"
                        local scopeLabel = selectionScopeLabel selectionData
                        local optionText = " | Rotate " + (if cb_arrRotate.checked then "On" else "Off") + " | Rescale " + (if cb_arrRescale.checked then "On" else "Off")
                        if cb_arrRescale.checked and not rescaleOK do optionText += "(failed)"
                        setStatus ((successCount as string) + "/" + (totalCount as string) + " " + scopeLabel + " shells | " + axisLabel + " | Pad " + (formattedPrint gap format:".4f") + optionText)
                        result = (successCount > 0)
                    )
                )

                isBusy = false
                result
            )
        )


        fn compactItemArea item =
        (
            if item == undefined or item.count < 2 then 0.0
            else
            (
                local bb = item[2]
                bb[5] * bb[6]
            )
        )

        fn compactItemThinness item =
        (
            if item == undefined or item.count < 2 then 0.0
            else
            (
                local bb = item[2]
                local smallDim = if bb[5] < bb[6] then bb[5] else bb[6]
                local largeDim = if bb[5] > bb[6] then bb[5] else bb[6]
                if smallDim <= 0.0000001 then 999999.0 else (largeDim / smallDim)
            )
        )

        fn sortCompactItems items =
        (
            -- Large/normal shells first. Very thin strips deliberately go last,
            -- even when their bounding-box area is relatively large.
            local sorted = #()
            local thinThreshold = 5.0

            for item in items do
            (
                local itemArea = compactItemArea item
                local itemThin = compactItemThinness item
                local itemClass = if itemThin >= thinThreshold then 1 else 0
                local inserted = false

                for i = 1 to sorted.count while not inserted do
                (
                    local other = sorted[i]
                    local otherArea = compactItemArea other
                    local otherThin = compactItemThinness other
                    local otherClass = if otherThin >= thinThreshold then 1 else 0

                    local before = false
                    if itemClass < otherClass then
                        before = true
                    else if itemClass == otherClass and itemArea > otherArea then
                        before = true
                    else if itemClass == otherClass and abs(itemArea - otherArea) <= 0.00000001 then
                    (
                        -- For equal area, keep the less extreme aspect first.
                        if itemThin < otherThin do before = true
                    )

                    if before do
                    (
                        insertItem item sorted i
                        inserted = true
                    )
                )

                if not inserted do append sorted item
            )
            sorted
        )

        fn packHorizontalShelves sortedItems targetWidth gap =
        (
            local rows = #()
            local rowItems = #()
            local rowWidth = 0.0
            local rowHeight = 0.0

            for item in sortedItems do
            (
                local bb = item[2]
                local w = bb[5]
                local h = bb[6]
                local nextWidth = if rowItems.count == 0 then w else (rowWidth + gap + w)

                if rowItems.count > 0 and nextWidth > targetWidth then
                (
                    append rows #(rowItems, rowWidth, rowHeight)
                    rowItems = #()
                    rowWidth = 0.0
                    rowHeight = 0.0
                )

                append rowItems item
                if rowItems.count == 1 then rowWidth = w else rowWidth += gap + w
                if h > rowHeight do rowHeight = h
            )

            if rowItems.count > 0 do append rows #(rowItems, rowWidth, rowHeight)
            if rows.count == 0 then return undefined

            local blockWidth = 0.0
            local blockHeight = 0.0
            for row in rows do
            (
                if row[2] > blockWidth do blockWidth = row[2]
                blockHeight += row[3]
            )
            if rows.count > 1 do blockHeight += gap * (rows.count - 1)

            local placements = #()
            local yCursor = blockHeight * 0.5

            for row in rows do
            (
                local rowItemsLocal = row[1]
                local rowWidthLocal = row[2]
                local rowHeightLocal = row[3]
                local xCursor = -(rowWidthLocal * 0.5)
                local rowCenterY = yCursor - (rowHeightLocal * 0.5)

                for item in rowItemsLocal do
                (
                    local bb = item[2]
                    local cx = xCursor + (bb[5] * 0.5)
                    append placements #(item, cx, rowCenterY)
                    xCursor += bb[5] + gap
                )

                yCursor -= rowHeightLocal + gap
            )

            #(placements, blockWidth, blockHeight)
        )

        fn packVerticalShelves sortedItems targetHeight gap =
        (
            local cols = #()
            local colItems = #()
            local colWidth = 0.0
            local colHeight = 0.0

            for item in sortedItems do
            (
                local bb = item[2]
                local w = bb[5]
                local h = bb[6]
                local nextHeight = if colItems.count == 0 then h else (colHeight + gap + h)

                if colItems.count > 0 and nextHeight > targetHeight then
                (
                    append cols #(colItems, colWidth, colHeight)
                    colItems = #()
                    colWidth = 0.0
                    colHeight = 0.0
                )

                append colItems item
                if colItems.count == 1 then colHeight = h else colHeight += gap + h
                if w > colWidth do colWidth = w
            )

            if colItems.count > 0 do append cols #(colItems, colWidth, colHeight)
            if cols.count == 0 then return undefined

            local blockWidth = 0.0
            local blockHeight = 0.0
            for col in cols do
            (
                blockWidth += col[2]
                if col[3] > blockHeight do blockHeight = col[3]
            )
            if cols.count > 1 do blockWidth += gap * (cols.count - 1)

            local placements = #()
            local xCursor = -(blockWidth * 0.5)

            for col in cols do
            (
                local colItemsLocal = col[1]
                local colWidthLocal = col[2]
                local colHeightLocal = col[3]
                local colCenterX = xCursor + (colWidthLocal * 0.5)
                local yCursor = colHeightLocal * 0.5

                for item in colItemsLocal do
                (
                    local bb = item[2]
                    local cy = yCursor - (bb[6] * 0.5)
                    append placements #(item, colCenterX, cy)
                    yCursor -= bb[6] + gap
                )

                xCursor += colWidthLocal + gap
            )

            #(placements, blockWidth, blockHeight)
        )

        fn compactPackScore packData desiredRatio =
        (
            if packData == undefined or packData.count < 3 then 1e30
            else
            (
                local w = packData[2]
                local h = packData[3]
                if w <= 0.0000001 or h <= 0.0000001 then 1e30
                else
                (
                    local area = w * h
                    local ratio = w / h
                    local penalty = abs(ratio - desiredRatio) / desiredRatio
                    area * (1.0 + (penalty * 0.20))
                )
            )
        )

        fn findBestCompactPack sortedItems orientation gap =
        (
            if sortedItems.count == 0 then return undefined

            local totalArea = 0.0
            local maxW = 0.0
            local maxH = 0.0
            for item in sortedItems do
            (
                local bb = item[2]
                totalArea += bb[5] * bb[6]
                if bb[5] > maxW do maxW = bb[5]
                if bb[6] > maxH do maxH = bb[6]
            )

            if totalArea <= 0.0000001 then return undefined

            local desiredRatio = if orientation == #horizontal then 1.65 else (1.0 / 1.65)
            local bestPack = undefined
            local bestScore = 1e30
            local factors = #(0.72, 0.84, 0.94, 1.0, 1.08, 1.20, 1.36, 1.55)

            if orientation == #horizontal then
            (
                local baseWidth = sqrt(totalArea * desiredRatio)
                for f in factors do
                (
                    local targetWidth = if maxW > (baseWidth * f) then maxW else (baseWidth * f)
                    local candidate = packHorizontalShelves sortedItems targetWidth gap
                    local score = compactPackScore candidate desiredRatio
                    if score < bestScore do
                    (
                        bestScore = score
                        bestPack = candidate
                    )
                )
            )
            else
            (
                local baseHeight = sqrt(totalArea / desiredRatio)
                for f in factors do
                (
                    local targetHeight = if maxH > (baseHeight * f) then maxH else (baseHeight * f)
                    local candidate = packVerticalShelves sortedItems targetHeight gap
                    local score = compactPackScore candidate desiredRatio
                    if score < bestScore do
                    (
                        bestScore = score
                        bestPack = candidate
                    )
                )
            )

            bestPack
        )

        fn coordAlreadyExists coords value =
        (
            local found = false
            for c in coords while not found do
            (
                if abs(c - value) <= 0.0000001 do found = true
            )
            found
        )

        fn placementOverlaps x y w h placed gap =
        (
            local hit = false
            for p in placed while not hit do
            (
                local px = p[2]
                local py = p[3]
                local pw = p[4]
                local ph = p[5]
                local separated = ((x + w + gap) <= px) or ((px + pw + gap) <= x) or ((y + h + gap) <= py) or ((py + ph + gap) <= y)
                if not separated do hit = true
            )
            hit
        )

        fn gapFillCandidateScore width height desiredRatio =
        (
            if width <= 0.0000001 or height <= 0.0000001 then 1e30
            else
            (
                local area = width * height
                local ratio = width / height
                local ratioPenalty = abs(ratio - desiredRatio) / desiredRatio
                area * (1.0 + ratioPenalty * 0.30)
            )
        )

        fn findGapFillPack sortedItems orientation gap =
        (
            if sortedItems == undefined or sortedItems.count < 1 then return undefined

            -- For very large shell counts, use the fast shelf solver rather than
            -- an expensive candidate-grid search.
            if sortedItems.count > 140 then return findBestCompactPack sortedItems orientation gap

            local desiredRatio = if orientation == #horizontal then 1.70 else (1.0 / 1.70)
            local placed = #()
            local currentW = 0.0
            local currentH = 0.0

            for itemIndex = 1 to sortedItems.count do
            (
                local item = sortedItems[itemIndex]
                local bb = item[2]
                local w = bb[5]
                local h = bb[6]

                if itemIndex == 1 then
                (
                    append placed #(item, 0.0, 0.0, w, h)
                    currentW = w
                    currentH = h
                )
                else
                (
                    local xs = #(0.0)
                    local ys = #(0.0)
                    for p in placed do
                    (
                        local newX = p[2] + p[4] + gap
                        local newY = p[3] + p[5] + gap
                        if not coordAlreadyExists xs newX do append xs newX
                        if not coordAlreadyExists ys newY do append ys newY
                    )

                    local bestX = undefined
                    local bestY = undefined
                    local bestW = 0.0
                    local bestH = 0.0
                    local bestScore = 1e30
                    local bestArea = 1e30

                    for x in xs do
                    (
                        for y in ys do
                        (
                            if not placementOverlaps x y w h placed gap do
                            (
                                local candidateW = if (x + w) > currentW then (x + w) else currentW
                                local candidateH = if (y + h) > currentH then (y + h) else currentH
                                local score = gapFillCandidateScore candidateW candidateH desiredRatio
                                local area = candidateW * candidateH

                                if score < (bestScore - 0.00000001) or (abs(score - bestScore) <= 0.00000001 and area < bestArea) do
                                (
                                    bestScore = score
                                    bestArea = area
                                    bestX = x
                                    bestY = y
                                    bestW = candidateW
                                    bestH = candidateH
                                )
                            )
                        )
                    )

                    -- Safety fallback: append to the primary growth direction.
                    if bestX == undefined then
                    (
                        if orientation == #horizontal then
                        (
                            bestX = currentW + gap
                            bestY = 0.0
                        )
                        else
                        (
                            bestX = 0.0
                            bestY = currentH + gap
                        )
                        bestW = if (bestX + w) > currentW then (bestX + w) else currentW
                        bestH = if (bestY + h) > currentH then (bestY + h) else currentH
                    )

                    append placed #(item, bestX, bestY, w, h)
                    currentW = bestW
                    currentH = bestH
                )
            )

            local placements = #()
            for p in placed do
            (
                local cx = p[2] + (p[4] * 0.5) - (currentW * 0.5)
                local cy = p[3] + (p[5] * 0.5) - (currentH * 0.5)
                append placements #(p[1], cx, cy)
            )

            #(placements, currentW, currentH)
        )

        fn arrangeCompactBlock orientation =
        (
            if isBusy then false
            else
            (
                isBusy = true
                uv = resolveUnwrap()
                local result = false

                if ensureUnwrapReady() then
                (
                    local selectionData = getCurrentSelectionAsVertices()
                    local allTopologyIslands = buildAllUVIslands()
                    local topologyIslands = filterTopologyIslandsBySelection allTopologyIslands selectionData
                    local initialItems = buildArrangementItems topologyIslands
                    local totalCount = initialItems.count

                    if totalCount < 1 then
                    (
                        if selectionData != undefined do restoreUVSelection selectionData
                        messageBox "No valid UV shells could be detected in the active Unwrap." title:"Rotate UV"
                        setStatus "Compact Block: no UV shells detected."
                    )
                    else
                    (
                        local originalCenter = arrangementGroupCenter initialItems
                        local gap = spn_spacing.value
                        local successCount = 0
                        local rescaleOK = true
                        local packData = undefined
                        local oldElementMode = undefined
                        local oldLock = undefined
                        try(oldElementMode = uv.getTVElementMode())catch(oldElementMode = undefined)
                        try(oldLock = uv.getLock())catch(oldLock = undefined)

                        undo "Compact Arrange UV Islands" on
                        (
                            try(uv.setTVElementMode false)catch()
                            try(uv.setLock false)catch()
                            try(uv.setTVSubObjectMode 1)catch()

                            if cb_arrRescale.checked do rescaleOK = rescaleTopologyIslands topologyIslands
                            if cb_arrRotate.checked do rotateTopologyIslandsForArrange topologyIslands orientation

                            local items = buildArrangementItems topologyIslands
                            local sortedItems = sortCompactItems items
                            packData = if cb_fillGaps.checked then (findGapFillPack sortedItems orientation gap) else (findBestCompactPack sortedItems orientation gap)

                            if packData != undefined do
                            (
                                local groupCenterX = if originalCenter == undefined then 0.0 else originalCenter[1]
                                local groupCenterY = if originalCenter == undefined then 0.0 else originalCenter[2]
                                local placements = packData[1]

                                for placement in placements do
                                (
                                    local item = placement[1]
                                    local islandData = item[1]
                                    local bb = item[2]
                                    local targetX = groupCenterX + placement[2]
                                    local targetY = groupCenterY + placement[3]
                                    if moveIslandVerts islandData[1] [targetX - bb[7], targetY - bb[8], 0] do successCount += 1
                                )
                            )

                            if oldLock != undefined do try(uv.setLock oldLock)catch()
                            if oldElementMode != undefined do try(uv.setTVElementMode oldElementMode)catch()
                            if selectionData != undefined do restoreUVSelection selectionData
                        )

                        try(uv.updateMap())catch()
                        try(uv.invalidateView())catch()
                        try(redrawViews())catch()

                        if packData == undefined then
                        (
                            setStatus "Compact Block: could not build a layout."
                        )
                        else
                        (
                            local modeLabel = if orientation == #horizontal then "Compact Block H" else "Compact Block V"
                            local scopeLabel = selectionScopeLabel selectionData
                            local blockW = packData[2]
                            local blockH = packData[3]
                            local fillLabel = if cb_fillGaps.checked then "Fill Gaps" else "Shelves"
                            local optionText = " | " + fillLabel + " | Rotate " + (if cb_arrRotate.checked then "On" else "Off") + " | Rescale " + (if cb_arrRescale.checked then "On" else "Off")
                            if cb_arrRescale.checked and not rescaleOK do optionText += "(failed)"
                            setStatus ((successCount as string) + "/" + (totalCount as string) + " " + scopeLabel + " shells | " + modeLabel + " | " + (formattedPrint blockW format:".3f") + " x " + (formattedPrint blockH format:".3f") + optionText)
                            result = successCount > 0
                        )
                    )
                )

                isBusy = false
                result
            )
        )


        -- Auto/captured topology rotations always use the island center.
        fn topologyPivot islandData =
        (
            if islandData == undefined or islandData.count < 1 then undefined
            else centerFromVerts islandData[1]
        )

        fn captureIslands =
        (
            if isBusy then false
            else
            (
                isBusy = true
                clearCapture updateButton:false
                uv = resolveUnwrap()

                local result = false
                if ensureUnwrapReady() then
                (
                    capturedNode = if selection.count == 1 then selection[1] else undefined
                    capturedMode = rb_workMode.state

                    if capturedMode == 1 then
                    (
                        -- AUTO CAPTURE uses the active UV component selection as
                        -- a shell filter.  Partial face/edge/vertex selections are
                        -- promoted to their complete UV shells.  With no active
                        -- UV selection it deliberately falls back to all shells.
                        local selectionData = getCurrentSelectionAsVertices()
                        local allTopologyIslands = buildAllUVIslands()
                        capturedTopologyIslands = filterTopologyIslandsBySelection allTopologyIslands selectionData
                        local scopeLabel = selectionScopeLabel selectionData
                        setStatus ("Scanning " + scopeLabel + " UV shells...")
                        capturedSelectionData = selectionData
                        restoreUVSelection selectionData

                        if capturedTopologyIslands.count > 0 then
                        (
                            chk_capture.state = true
                            chk_capture.text = ("CAPTURED: " + capturedTopologyIslands.count as string + " ISLANDS")
                            local scopeLabel2 = selectionScopeLabel selectionData
                            setStatus ((capturedTopologyIslands.count as string) + " " + scopeLabel2 + " UV shells captured - ready.")
                            result = true
                        )
                        else
                        (
                            clearCapture updateButton:false
                            chk_capture.state = false
                            messageBox "No valid UV shells could be detected in the active Unwrap." title:"Rotate UV"
                            setStatus "Nothing captured."
                        )
                    )
                    else
                    (
                        -- MANUAL CAPTURE remains one selected reference edge per shell.
                        local subMode = 0
                        try(subMode = uv.getTVSubObjectMode())catch(subMode = 0)
                        if subMode != 2 then
                        (
                            chk_capture.state = false
                            messageBox "Manual mode requires EDGE sub-object mode. Select one reference edge per island, then Capture Islands." title:"Rotate UV"
                            setStatus "Manual capture: Edge mode required."
                        )
                        else if buildReferenceEdges capturedMode then
                        (
                            chk_capture.state = true
                            chk_capture.text = ("CAPTURED: " + referenceEdges.count as string + " ISLANDS")
                            setStatus ((referenceEdges.count as string) + " manual islands captured - ready.")
                            result = true
                        )
                        else
                        (
                            clearCapture updateButton:false
                            chk_capture.state = false
                            messageBox "No valid UV edge selection was found." title:"Rotate UV"
                            setStatus "Nothing captured."
                        )
                    )
                )
                else
                (
                    chk_capture.state = false
                )

                isBusy = false
                result
            )
        )

        fn restoreCapturedSelection =
        (
            if uv != undefined do
            (
                if capturedMode == 1 and capturedSelectionData != undefined then
                    restoreUVSelection capturedSelectionData
                else if capturedEdges != undefined do
                    try(uv.selectEdges capturedEdges)catch()
            )
        )

        fn rotateCaptured angleDeg =
        (
            if captureStillValid() then
            (
                local successCount = 0

                if capturedMode == 1 then
                (
                    local oldElementMode = undefined
                    local oldLock = undefined
                    try(oldElementMode = uv.getTVElementMode())catch(oldElementMode = undefined)
                    try(oldLock = uv.getLock())catch(oldLock = undefined)

                    undo "Rotate UV" on
                    (
                        try(uv.setTVElementMode false)catch()
                        try(uv.setLock false)catch()
                        try(uv.setTVSubObjectMode 1)catch()

                        for islandData in capturedTopologyIslands do
                        (
                            local pivot = topologyPivot islandData
                            if rotateIslandVerts islandData[1] (degToRad angleDeg) pivot do successCount += 1
                        )

                        if oldLock != undefined do try(uv.setLock oldLock)catch()
                        if oldElementMode != undefined do try(uv.setTVElementMode oldElementMode)catch()
                        restoreCapturedSelection()
                    )
                    setStatus ((successCount as string) + "/" + (capturedTopologyIslands.count as string) + " islands rotated " + (formattedPrint angleDeg format:".1f") + " deg.")
                )
                else
                (
                    undo "Rotate UV" on
                    (
                        for refEdge in referenceEdges do
                        (
                            if rotateIsland refEdge (degToRad angleDeg) do successCount += 1
                        )
                        restoreCapturedSelection()
                    )
                    setStatus ((successCount as string) + "/" + (referenceEdges.count as string) + " islands rotated " + (formattedPrint angleDeg format:".1f") + " deg.")
                )
            )
        )

        -- Pro rotation action:
        -- 1) If Capture Islands is active, rotate the captured shells.
        -- 2) Otherwise rotate the LIVE UV selection.
        -- 3) Auto mode with no active UV selection deliberately rotates all shells,
        --    matching the tool's existing selection-scope rule.
        fn rotateCurrentSelection angleDeg =
        (
            if isBusy then false
            else
            (
                isBusy = true
                uv = resolveUnwrap()
                local result = false

                if ensureUnwrapReady() then
                (
                    local subMode = 0
                    try(subMode = uv.getTVSubObjectMode())catch(subMode = 0)

                    if rb_workMode.state == 1 then
                    (
                        local selectionData = getCurrentSelectionAsVertices()
                        local allTopologyIslands = buildAllUVIslands()
                        local topologyIslands = filterTopologyIslandsBySelection allTopologyIslands selectionData
                        local scopeLabel = selectionScopeLabel selectionData
                        local totalCount = topologyIslands.count
                        local successCount = 0
                        local oldElementMode = undefined
                        local oldLock = undefined

                        try(oldElementMode = uv.getTVElementMode())catch(oldElementMode = undefined)
                        try(oldLock = uv.getLock())catch(oldLock = undefined)

                        if totalCount < 1 then
                        (
                            if selectionData != undefined do restoreUVSelection selectionData
                            messageBox "No UV shells could be detected in the active Unwrap." title:"Rotate UV"
                            setStatus "Rotate: no UV shells detected."
                        )
                        else
                        (
                            undo "Rotate UV" on
                            (
                                try(uv.setTVElementMode false)catch()
                                try(uv.setLock false)catch()
                                try(uv.setTVSubObjectMode 1)catch()

                                for islandData in topologyIslands do
                                (
                                    local pivot = topologyPivot islandData
                                    if rotateIslandVerts islandData[1] (degToRad angleDeg) pivot do successCount += 1
                                )

                                if oldLock != undefined do try(uv.setLock oldLock)catch()
                                if oldElementMode != undefined do try(uv.setTVElementMode oldElementMode)catch()
                                if selectionData != undefined do restoreUVSelection selectionData
                            )

                            setStatus ("Rotate: " + (successCount as string) + "/" + (totalCount as string) + " " + scopeLabel + " shells | " + (formattedPrint angleDeg format:".1f") + " deg.")
                            result = successCount > 0
                        )
                    )
                    else
                    (
                        -- Manual mode rotates each island around the center of its
                        -- currently selected reference edge.
                        if subMode != 2 then
                        (
                            messageBox "Manual mode uses selected UV edges. Switch the UV Editor to EDGE mode and select one reference edge per island." title:"Rotate UV"
                            setStatus "Manual rotate: Edge mode required."
                        )
                        else
                        (
                            local originalSelection = undefined
                            try(originalSelection = copy (uv.getSelectedEdges()))catch(originalSelection = undefined)

                            if originalSelection == undefined or originalSelection.isEmpty then
                            (
                                messageBox "Select one UV reference edge on each island you want to rotate." title:"Rotate UV"
                                setStatus "Manual rotate: no UV edge selection."
                            )
                            else
                            (
                                local directRefs = buildDirectReferenceEdges originalSelection
                                local totalCount = directRefs.count
                                local successCount = 0

                                undo "Rotate UV" on
                                (
                                    for refEdge in directRefs do
                                    (
                                        if rotateIsland refEdge (degToRad angleDeg) do successCount += 1
                                    )
                                    try(uv.selectEdges originalSelection)catch()
                                )

                                setStatus ("Manual rotate: " + (successCount as string) + "/" + (totalCount as string) + " islands | " + (formattedPrint angleDeg format:".1f") + " deg.")
                                result = successCount > 0
                            )
                        )
                    )
                )

                isBusy = false
                result
            )
        )

        fn rotatePro angleDeg =
        (
            -- Capture remains useful for repeated rotations, but it is no longer
            -- mandatory.  If the capture is stale, clear it and use the live
            -- selection instead of making the buttons appear dead.
            if chk_capture.state then
            (
                if captureStillValid() then
                (
                    rotateCaptured angleDeg
                )
                else
                (
                    clearCapture()
                    rotateCurrentSelection angleDeg
                )
            )
            else
            (
                rotateCurrentSelection angleDeg
            )
        )

        fn alignCurrentSelection axisMode =
        (
            if isBusy then false
            else
            (
                isBusy = true
                uv = resolveUnwrap()
                local result = false

                if ensureUnwrapReady() then
                (
                    local subMode = 0
                    try(subMode = uv.getTVSubObjectMode())catch(subMode = 0)

                    if rb_workMode.state == 1 then
                    (
                        -- AUTO uses the ACTIVE UV selection as a shell filter.
                        -- Any selected face/element/edge/vertex promotes to its full
                        -- UV shell.  Unselected shells remain untouched.  If there
                        -- is no active UV selection, Auto deliberately processes all
                        -- shells to preserve the global workflow.
                        local selectionData = getCurrentSelectionAsVertices()
                        local allTopologyIslands = buildAllUVIslands()
                        local topologyIslands = filterTopologyIslandsBySelection allTopologyIslands selectionData
                        local scopeLabel = selectionScopeLabel selectionData

                        setStatus ("Auto: scanning " + scopeLabel + " UV shells...")

                        local totalCount = topologyIslands.count
                        local successCount = 0
                        local oldElementMode = undefined
                        local oldLock = undefined

                        try(oldElementMode = uv.getTVElementMode())catch(oldElementMode = undefined)
                        try(oldLock = uv.getLock())catch(oldLock = undefined)

                        if totalCount < 1 then
                        (
                            if selectionData != undefined do restoreUVSelection selectionData
                            messageBox "No UV shells could be detected in the active Unwrap." title:"Rotate UV"
                            setStatus "Auto: no UV shells detected."
                        )
                        else
                        (
                            undo "Auto Orient UV" on
                            (
                                try(uv.setTVElementMode false)catch()
                                try(uv.setLock false)catch()
                                try(uv.setTVSubObjectMode 1)catch()

                                for islandData in topologyIslands do
                                (
                                    if alignTopologyIslandCompact islandData axisMode do successCount += 1
                                )

                                if oldLock != undefined do try(uv.setLock oldLock)catch()
                                if oldElementMode != undefined do try(uv.setTVElementMode oldElementMode)catch()
                                restoreUVSelection selectionData
                            )

                            local axisText = if axisMode == #horizontal then "Horizontal" else "Vertical"
                            setStatus ("Auto: " + (successCount as string) + "/" + (totalCount as string) + " " + scopeLabel + " UV shells -> " + axisText + ".")
                            result = (successCount > 0)
                        )
                    )
                    else
                    (
                        -- MANUAL remains edge-driven: one selected reference edge per island.
                        if subMode != 2 then
                        (
                            messageBox "Manual mode uses selected UV edges. Switch the Unwrap UV Editor to EDGE mode, select one reference edge per island, then click Horizontal or Vertical." title:"Rotate UV"
                            setStatus "Manual: Edge sub-object mode required."
                        )
                        else
                        (
                            local originalSelection = undefined
                            try(originalSelection = uv.getSelectedEdges())catch(originalSelection = undefined)

                            if originalSelection == undefined or originalSelection.isEmpty then
                            (
                                messageBox "Select one UV reference edge on each island you want to align." title:"Rotate UV"
                                setStatus "Manual: no UV edge selection."
                            )
                            else
                            (
                                local directRefs = buildDirectReferenceEdges originalSelection
                                local totalCount = directRefs.count
                                local successCount = 0

                                undo "Align UV" on
                                (
                                    for refEdge in directRefs do
                                    (
                                        if alignIsland refEdge axisMode do successCount += 1
                                    )
                                    try(uv.selectEdges originalSelection)catch()
                                )

                                local axisText = if axisMode == #horizontal then "Horizontal" else "Vertical"
                                setStatus ("Manual: " + (successCount as string) + "/" + (totalCount as string) + " islands -> " + axisText + ".")
                                result = (successCount > 0)
                            )
                        )
                    )
                )

                isBusy = false
                result
            )
        )

        ----------------------------------------------------------------------
        -- UNFOLD3D V4 - EXISTING UV SHELL BOUNDARIES ONLY
        ----------------------------------------------------------------------
        fn getUnfoldTargetIslands selectionData =
        (
            local allTopologyIslands = buildAllUVIslands()
            if allTopologyIslands == undefined or allTopologyIslands.count < 1 then #()
            else filterTopologyIslandsBySelection allTopologyIslands selectionData
        )

        -- Return the OPEN UV edges that form one shell's existing boundary.
        -- openEdgeSelect() has a long-standing behavior where the seed edge can
        -- remain in the selection, so we subtract each seed and union only the
        -- open edges discovered around it.  islandData[2] already contains the
        -- expected number of UV boundary edge pairs, allowing an early exit.
        fn getIslandOpenUVEdges islandData =
        (
            local openEdges = #{}
            if islandData == undefined or islandData.count < 3 then return openEdges
            if islandData[2] == undefined or islandData[2].count < 1 then return openEdges

            local faceSet = islandData[3]
            local shellEdges = #{}
            local expectedOpen = islandData[2].count

            try
            (
                uv.setTVSubObjectMode 3
                uv.selectFaces faceSet
                uv.faceToEdgeSelect()
                shellEdges = copy (uv.getSelectedEdges())
            )
            catch(shellEdges = #{})

            if shellEdges == undefined or shellEdges.isEmpty then return openEdges

            for edgeID in shellEdges while openEdges.numberSet < expectedOpen do
            (
                local seed = #{edgeID}
                try
                (
                    uv.setTVSubObjectMode 2
                    uv.selectEdges seed
                    uv.openEdgeSelect()
                    local discovered = copy (uv.getSelectedEdges())
                    if discovered != undefined do
                    (
                        discovered = discovered - seed
                        if not discovered.isEmpty do openEdges += discovered
                    )
                )
                catch()
            )

            openEdges
        )

        fn restoreIslandCenter islandData oldCenter =
        (
            if islandData == undefined or oldCenter == undefined then false
            else
            (
                local newCenter = centerFromVerts islandData[1]
                if newCenter == undefined then false
                else
                (
                    local offset = oldCenter - newCenter
                    if (distance oldCenter newCenter) > 0.00000001 then moveIslandVerts islandData[1] offset else true
                )
            )
        )

        fn getAllUVFaces =
        (
            local numFaces = 0
            try(numFaces = uv.numberPolygons())catch(numFaces = 0)
            local allFaces = #{}
            if numFaces > 0 do
            (
                allFaces.count = numFaces
                allFaces = -allFaces
            )
            allFaces
        )

        -- Unfold deliberately does NOT invent seams.  The last Auto Seam analysis
        -- scope is preferred after Preview/Apply so the selected preview edges do
        -- not accidentally reduce the solve to only faces touching those edges.
        fn getExplicitUnfoldFaceScope selectionData =
        (
            local node = activeUnwrapNode()
            if seamAnalysisValid and seamAnalysisNode == node and seamTargetFaces != undefined and not seamTargetFaces.isEmpty then
            (
                copy seamTargetFaces
            )
            else if selectionData != undefined and selectionData.count >= 4 and selectionData[1] == 3 and not selectionData[4].isEmpty then
            (
                copy selectionData[4]
            )
            else
            (
                getAllUVFaces()
            )
        )

        fn runUnfold3D optimizeOnly:false =
        (
            if isBusy then false
            else
            (
                isBusy = true
                uv = resolveUnwrap()
                local result = false
                local selectionData = undefined

                if ensureUnwrapReady() then
                (
                    selectionData = getCurrentSelectionAsVertices()
                    local faceSel = getExplicitUnfoldFaceScope selectionData

                    if faceSel == undefined or faceSel.isEmpty then
                    (
                        setStatus "Unfold: no faces available."
                    )
                    else
                    (
                        local canRun = true
                        local currentSeams = #{}
                        if not optimizeOnly do
                        (
                            try(currentSeams = copy (uv.getPeltSelectedSeams()))catch(currentSeams = #{})
                            if currentSeams == undefined or currentSeams.isEmpty do
                            (
                                canRun = false
                                setStatus "Unfold: define/apply seams first."
                                messageBox "Unfold needs Peel/Pelt seams first.

Use Auto Seam: Generate -> Preview -> Apply, or define seams manually in Edit UVWs, then press Unfold." title:"Rotate UV - Unfold"
                            )
                        )

                        if canRun do
                        (
                            local oldElementMode = undefined
                            local oldLock = undefined
                            try(oldElementMode = uv.getTVElementMode())catch(oldElementMode = undefined)
                            try(oldLock = uv.getLock())catch(oldLock = undefined)

                            try
                            (
                                local undoLabel = if optimizeOnly then "Optimize UVs" else "Unfold From Seams"
                                undo undoLabel on
                                (
                                    try(uv.setTVElementMode false)catch()
                                    try(uv.setLock false)catch()
                                    uv.setTVSubObjectMode 3
                                    uv.selectFaces faceSel

                                    if optimizeOnly then
                                    (
                                        uv.Unfold3DOptimize()
                                    )
                                    else
                                    (
                                        uv.Unfold3DSolve()
                                        uv.selectFaces faceSel
                                        uv.Unfold3DOptimize()
                                    )

                                    if oldLock != undefined do try(uv.setLock oldLock)catch()
                                    if oldElementMode != undefined do try(uv.setTVElementMode oldElementMode)catch()
                                    if selectionData != undefined do restoreUVSelection selectionData
                                    try(uv.updateMap())catch()
                                    try(uv.invalidateView())catch()
                                    try(redrawViews())catch()
                                )
                                result = true
                                if optimizeOnly then
                                    setStatus ("Optimize: " + (faceSel.numberSet as string) + " faces.")
                                else
                                    setStatus ("Unfold: " + (faceSel.numberSet as string) + " faces from explicit seams.")
                            )
                            catch
                            (
                                if oldLock != undefined do try(uv.setLock oldLock)catch()
                                if oldElementMode != undefined do try(uv.setTVElementMode oldElementMode)catch()
                                if selectionData != undefined do restoreUVSelection selectionData
                                result = false
                                messageBox ((if optimizeOnly then "Optimize failed.

" else "Unfold failed.

") + getCurrentException()) title:"Rotate UV - Unfold"
                            )
                        )
                    )
                )

                if selectionData != undefined do restoreUVSelection selectionData
                isBusy = false
                result
            )
        )

        -- Convert the ACTIVE live UV component selection to texture polygons,
        -- WITHOUT promoting it to complete UV shells. Used by Straighten UV.
        fn getActiveSelectionFaces selectionData =
        (
            local faces = #{}
            if selectionData == undefined or selectionData.count < 5 then return faces

            local subMode = selectionData[1]
            try
            (
                case subMode of
                (
                    1:
                    (
                        if not selectionData[2].isEmpty do
                        (
                            uv.setTVSubObjectMode 1
                            uv.selectVertices selectionData[2]
                            uv.vertToFaceSelect()
                            faces = copy (uv.getSelectedFaces())
                        )
                    )
                    2:
                    (
                        if not selectionData[3].isEmpty do
                        (
                            uv.setTVSubObjectMode 2
                            uv.selectEdges selectionData[3]
                            uv.edgeToFaceSelect()
                            faces = copy (uv.getSelectedFaces())
                        )
                    )
                    3:
                    (
                        faces = copy selectionData[4]
                    )
                )
            )
            catch(faces = #{})

            faces
        )

        ----------------------------------------------------------------------
        -- SHAPE-AWARE AUTO SEAM V5
        --
        -- Conservative seam proposal only.  It does not modify topology until
        -- Apply is pressed.
        --
        -- 1) Strict coplanar regions describe hard-surface panels.
        -- 2) A maximum-keep region tree creates a connected, low-cut panel net.
        -- 3) Smooth components with two dominant disconnected boundary loops are
        --    treated as tube/pipe strips: hard attachment boundaries are cut and
        --    one shortest geometry path opens the tube longitudinally.
        -- 4) Very smooth closed components are left for manual seams instead of
        --    receiving an arbitrary star/spiral cut.
        ----------------------------------------------------------------------
        fn seamEdgeRecordCompare a b =
        (
            if a[1] < b[1] then -1
            else if a[1] > b[1] then 1
            else if a[2] < b[2] then -1
            else if a[2] > b[2] then 1
            else if a[3] < b[3] then -1
            else if a[3] > b[3] then 1
            else 0
        )

        fn seamPairExists pair pairArray =
        (
            local found = false
            if pair != undefined and pair.count >= 2 do
            (
                for p in pairArray while not found do
                (
                    if p[1] == pair[1] and p[2] == pair[2] do found = true
                )
            )
            found
        )

        fn seamAppendUniquePair pair pairArray =
        (
            if pair != undefined and pair.count >= 2 and pair[1] > 0 and pair[2] > 0 do
            (
                if not (seamPairExists pair pairArray) do append pairArray pair
            )
            pairArray
        )

        fn seamGeomEdgeLength g1 g2 geomMesh =
        (
            local d = 1.0
            if geomMesh != undefined do
            (
                try
                (
                    local nv = getNumVerts geomMesh
                    if g1 > 0 and g2 > 0 and g1 <= nv and g2 <= nv do
                    (
                        local p1 = getVert geomMesh g1
                        local p2 = getVert geomMesh g2
                        local dd = distance p1 p2
                        if dd > 0.00000001 do d = dd
                    )
                )
                catch(d = 1.0)
            )
            d
        )

        ----------------------------------------------------------------------
        -- TOPOLOGY + EDGE-FLOW ATLAS V8
        --
        -- Primary rule:
        --   TRUE / EFFECTIVE OPEN MESH BOUNDARIES ARE ALREADY CUT.
        --   They are never proposed as new seams.
        --
        -- The analyzer works on arbitrary geometry. It does not classify the
        -- object as a box, tube, head, ear, statue, etc. For each connected
        -- surface component it first finds its open boundary components. It
        -- then adds the minimum useful seam chains:
        --   * 2+ open boundaries -> connect boundary components with shortest
        --     low-cost paths (tube/handle/spout naturally gets one lengthwise cut)
        --   * 0 open boundaries  -> add one conservative diameter slit
        --   * 1 open boundary    -> already topologically open; only add one
        --     relief slit when intrinsic curvature indicates it is worthwhile
        --
        -- Existing UV seams are treated as almost-free paths and are not
        -- proposed again. Sharp/folded edges are slightly preferred, but
        -- curvature never creates whole rings by itself.
        ----------------------------------------------------------------------

        fn atlasHeapPush heap item =
        (
            append heap item
            local i = heap.count
            local moving = true
            while i > 1 and moving do
            (
                local p = floor (i / 2.0)
                if heap[p][1] <= item[1] then
                    moving = false
                else
                (
                    heap[i] = heap[p]
                    i = p
                )
            )
            heap[i] = item
            true
        )

        fn atlasHeapPop heap =
        (
            if heap.count < 1 then undefined
            else
            (
                local root = heap[1]
                local last = heap[heap.count]
                deleteItem heap heap.count
                if heap.count > 0 do
                (
                    local i = 1
                    local moving = true
                    while moving do
                    (
                        local l = i * 2
                        local r = l + 1
                        if l > heap.count then
                            moving = false
                        else
                        (
                            local c = l
                            if r <= heap.count and heap[r][1] < heap[l][1] do c = r
                            if heap[c][1] >= last[1] then
                                moving = false
                            else
                            (
                                heap[i] = heap[c]
                                i = c
                            )
                        )
                    )
                    heap[i] = last
                )
                root
            )
        )

        fn v7DijkstraFromSet sourceVerts vertGraph maxGeomVert =
        (
            local inf = 1.0e30
            local dist = for i = 1 to maxGeomVert collect inf
            local prevV = for i = 1 to maxGeomVert collect 0
            local prevG = for i = 1 to maxGeomVert collect 0
            local heap = #()

            if sourceVerts != undefined do
            (
                for sv in sourceVerts do
                (
                    if sv > 0 and sv <= maxGeomVert do
                    (
                        dist[sv] = 0.0
                        atlasHeapPush heap #(0.0, sv)
                    )
                )
            )

            while heap.count > 0 do
            (
                local item = atlasHeapPop heap
                if item != undefined do
                (
                    local d = item[1]
                    local v = item[2]
                    if d <= (dist[v] + 0.0000001) and vertGraph[v] != undefined do
                    (
                        for ar in vertGraph[v] do
                        (
                            local nv = ar[1]
                            local gi = ar[2]
                            local step = ar[3]
                            local nd = d + step
                            if nd < (dist[nv] - 0.0000001) do
                            (
                                dist[nv] = nd
                                prevV[nv] = v
                                prevG[nv] = gi
                                atlasHeapPush heap #(nd, nv)
                            )
                        )
                    )
                )
            )
            #(dist, prevV, prevG)
        )

        fn v7PathGroupsToVertex targetV dijkstraData =
        (
            local result = #()
            if dijkstraData == undefined or targetV <= 0 then return result
            local prevV = dijkstraData[2]
            local prevG = dijkstraData[3]
            local v = targetV
            local safety = 0
            while v > 0 and v <= prevV.count and prevV[v] != 0 and safety < (prevV.count + 4) do
            (
                safety += 1
                if prevG[v] > 0 do append result prevG[v]
                v = prevV[v]
            )
            result
        )

        fn v7ShortestPathBetweenSets sourceVerts targetVerts vertGraph maxGeomVert =
        (
            if sourceVerts == undefined or targetVerts == undefined or sourceVerts.isEmpty or targetVerts.isEmpty then undefined
            else
            (
                local dj = v7DijkstraFromSet sourceVerts vertGraph maxGeomVert
                local dist = dj[1]
                local bestV = 0
                local bestD = 1.0e30
                for v in targetVerts do
                (
                    if v > 0 and v <= maxGeomVert and dist[v] < bestD do
                    (
                        bestD = dist[v]
                        bestV = v
                    )
                )
                if bestV == 0 or bestD >= 1.0e29 then undefined
                else #(v7PathGroupsToVertex bestV dj, bestD, bestV)
            )
        )

        fn v7FarthestPathFromSet sourceVerts allowedVerts vertGraph maxGeomVert =
        (
            if sourceVerts == undefined or sourceVerts.isEmpty or allowedVerts == undefined or allowedVerts.isEmpty then undefined
            else
            (
                local dj = v7DijkstraFromSet sourceVerts vertGraph maxGeomVert
                local dist = dj[1]
                local bestV = 0
                local bestD = -1.0
                for v in allowedVerts do
                (
                    if v > 0 and v <= maxGeomVert and dist[v] < 1.0e29 and dist[v] > bestD do
                    (
                        bestD = dist[v]
                        bestV = v
                    )
                )
                if bestV == 0 then undefined
                else #(v7PathGroupsToVertex bestV dj, bestD, bestV, dj)
            )
        )

        fn v7DiameterPath allowedVerts vertGraph maxGeomVert =
        (
            if allowedVerts == undefined or allowedVerts.isEmpty then undefined
            else
            (
                local seed = 0
                for v in allowedVerts while seed == 0 do seed = v
                if seed == 0 then undefined
                else
                (
                    local src = #{seed}
                    local pass1 = v7FarthestPathFromSet src allowedVerts vertGraph maxGeomVert
                    if pass1 == undefined then undefined
                    else
                    (
                        local a = pass1[3]
                        local src2 = #{a}
                        local pass2 = v7FarthestPathFromSet src2 allowedVerts vertGraph maxGeomVert
                        if pass2 == undefined then undefined else #(pass2[1], pass2[2], a, pass2[3])
                    )
                )
            )
        )

        fn v7BoundaryComponents comp groups maxGeomVert =
        (
            local boundaryAdj = #()
            boundaryAdj.count = maxGeomVert
            local boundaryVerts = #{}
            local boundaryEdgeCount = 0
            local trueOpenEdgeCount = 0

            for gi = 1 to groups.count do
            (
                local g = groups[gi]
                local insideCount = 0
                for f in g[3] do if comp[f] do insideCount += 1
                if insideCount == 1 do
                (
                    local a = g[1]
                    local b = g[2]
                    if a > 0 and b > 0 and a <= maxGeomVert and b <= maxGeomVert do
                    (
                        if boundaryAdj[a] == undefined do boundaryAdj[a] = #{}
                        if boundaryAdj[b] == undefined do boundaryAdj[b] = #{}
                        boundaryAdj[a][b] = true
                        boundaryAdj[b][a] = true
                        boundaryVerts[a] = true
                        boundaryVerts[b] = true
                        boundaryEdgeCount += 1
                        if g[6] do trueOpenEdgeCount += 1
                    )
                )
            )

            local components = #()
            local seen = #{}
            for sv in boundaryVerts do if not seen[sv] do
            (
                local bc = #{}
                local q = #(sv)
                local qi = 1
                seen[sv] = true
                while qi <= q.count do
                (
                    local cv = q[qi]
                    qi += 1
                    bc[cv] = true
                    if boundaryAdj[cv] != undefined do
                    (
                        for nv in boundaryAdj[cv] do if not seen[nv] do
                        (
                            seen[nv] = true
                            append q nv
                        )
                    )
                )
                if not bc.isEmpty do append components bc
            )
            #(components, boundaryVerts, boundaryEdgeCount, trueOpenEdgeCount)
        )

        fn v7ComponentVerts comp groups =
        (
            local verts = #{}
            for gi = 1 to groups.count do
            (
                local g = groups[gi]
                local inside = false
                for f in g[3] while not inside do if comp[f] do inside = true
                if inside do
                (
                    verts[g[1]] = true
                    verts[g[2]] = true
                )
            )
            verts
        )

        fn v7AppendPathGroups pathGroups candidateGroups groups =
        (
            local added = 0
            if pathGroups != undefined do
            (
                for gi in pathGroups do
                (
                    if gi > 0 and gi <= groups.count do
                    (
                        local g = groups[gi]
                        -- Never propose a true open geometry boundary, and never
                        -- re-propose an already split UV edge.
                        if not g[6] and not g[7] and not candidateGroups[gi] do
                        (
                            candidateGroups[gi] = true
                            added += 1
                        )
                    )
                )
            )
            added
        )

        -- V7.2 path append: terminal-cap interiors are protected. The terminal
        -- separator loop itself is allowed, but any ordinary seam group whose
        -- incident faces lie completely inside a protected cap is rejected.
        -- This makes a longitudinal/relief seam terminate at the cap loop rather
        -- than continuing through a triangulated pole or radial fan.
        fn v72AppendPathGroupsProtected pathGroups candidateGroups groups protectedCapFaces terminalLoopGroups =
        (
            local added = 0
            if pathGroups != undefined do
            (
                for gi in pathGroups do
                (
                    if gi > 0 and gi <= groups.count do
                    (
                        local g = groups[gi]
                        local isTerminalLoop = terminalLoopGroups != undefined and terminalLoopGroups[gi]
                        local fullyInsideCap = false

                        if protectedCapFaces != undefined and not protectedCapFaces.isEmpty and not isTerminalLoop do
                        (
                            local incidentCount = 0
                            local protectedCount = 0
                            for f in g[3] do
                            (
                                incidentCount += 1
                                if protectedCapFaces[f] do protectedCount += 1
                            )
                            fullyInsideCap = incidentCount > 0 and protectedCount == incidentCount
                        )

                        if not fullyInsideCap and not g[6] and not g[7] and not candidateGroups[gi] do
                        (
                            candidateGroups[gi] = true
                            added += 1
                        )
                    )
                )
            )
            added
        )

        ----------------------------------------------------------------------
        -- TERMINAL CAP SEPARATOR V7.2
        --
        -- This is deliberately NOT a general loop cutter. It searches only for
        -- closed, smooth continuation loops that isolate a relatively small,
        -- disk-like terminal region which does not touch an existing open mesh
        -- boundary. Nested candidates are collapsed to one best loop, so a
        -- rounded bottom does not receive a stack of concentric seams.
        ----------------------------------------------------------------------

        fn v71GroupInsideCount gi comp groups =
        (
            local c = 0
            if gi > 0 and gi <= groups.count do
            (
                for f in groups[gi][3] do if comp[f] do c += 1
            )
            c
        )

        fn v71OtherGroupVertex gi v groups =
        (
            if gi <= 0 or gi > groups.count then 0
            else
            (
                local g = groups[gi]
                if g[1] == v then g[2] else if g[2] == v then g[1] else 0
            )
        )

        fn v71BuildVertexGroups groups maxGeomVert comp =
        (
            local result = #()
            result.count = maxGeomVert
            for gi = 1 to groups.count do
            (
                if v71GroupInsideCount gi comp groups > 0 do
                (
                    local g = groups[gi]
                    local a = g[1]
                    local b = g[2]
                    if a > 0 and a <= maxGeomVert do
                    (
                        if result[a] == undefined do result[a] = #()
                        append result[a] gi
                    )
                    if b > 0 and b <= maxGeomVert do
                    (
                        if result[b] == undefined do result[b] = #()
                        append result[b] gi
                    )
                )
            )
            result
        )

        fn v71TraceClosedLoop seedGI comp groups vertGroups geomMesh maxGeomVert =
        (
            if geomMesh == undefined or seedGI <= 0 or seedGI > groups.count then undefined
            else
            (
                local sg = groups[seedGI]
                if sg[6] or v71GroupInsideCount seedGI comp groups != 2 then undefined
                else
                (
                    local startA = sg[1]
                    local startB = sg[2]
                    if startA <= 0 or startB <= 0 or startA > maxGeomVert or startB > maxGeomVert then undefined
                    else
                    (
                        local nv = 0
                        try(nv = getNumVerts geomMesh)catch(nv = 0)
                        if startA > nv or startB > nv then undefined
                        else
                        (
                            local loopGroups = #(seedGI)
                            local used = #{seedGI}
                            local prevV = startA
                            local curV = startB
                            local curGI = seedGI
                            local closed = false
                            local straightSum = 0.0
                            local straightCount = 0
                            local safety = 0
                            local maxSteps = amin #(groups.count + 4, 4096)

                            while not closed and safety < maxSteps do
                            (
                                safety += 1
                                local pPrev = getVert geomMesh prevV
                                local pCur = getVert geomMesh curV
                                local inVec = pCur - pPrev
                                if length inVec <= 0.0000001 then exit
                                inVec = normalize inVec

                                local bestGI = 0
                                local bestV = 0
                                local bestStraight = -2.0

                                if curV > 0 and curV <= vertGroups.count and vertGroups[curV] != undefined do
                                (
                                    for ngi in vertGroups[curV] do
                                    (
                                        if ngi != curGI and not groups[ngi][6] and v71GroupInsideCount ngi comp groups == 2 do
                                        (
                                            local ov = v71OtherGroupVertex ngi curV groups
                                            if ov > 0 and ov <= nv do
                                            (
                                                local canUse = not used[ngi]
                                                if ngi == seedGI and curV == startA and ov == startB and loopGroups.count >= 3 do canUse = true
                                                if canUse do
                                                (
                                                    local outVec = (getVert geomMesh ov) - pCur
                                                    if length outVec > 0.0000001 do
                                                    (
                                                        outVec = normalize outVec
                                                        local s = dot inVec outVec
                                                        if s > bestStraight do
                                                        (
                                                            bestStraight = s
                                                            bestGI = ngi
                                                            bestV = ov
                                                        )
                                                    )
                                                )
                                            )
                                        )
                                    )
                                )

                                -- Smooth edge loops on production meshes normally continue
                                -- with a positive tangent correlation. Reject right-angle
                                -- wandering so the detector cannot invent arbitrary rings.
                                if bestGI == 0 or bestStraight < 0.10 then exit

                                if bestGI == seedGI and curV == startA and bestV == startB then
                                (
                                    closed = true
                                )
                                else
                                (
                                    append loopGroups bestGI
                                    used[bestGI] = true
                                    straightSum += bestStraight
                                    straightCount += 1
                                    prevV = curV
                                    curV = bestV
                                    curGI = bestGI
                                )
                            )

                            if not closed or loopGroups.count < 4 then undefined
                            else
                            (
                                local avgStraight = if straightCount > 0 then straightSum / straightCount else 0.0
                                #(loopGroups, avgStraight)
                            )
                        )
                    )
                )
            )
        )

        fn v71SplitFacesByLoop comp loopGroups groups numFaces =
        (
            if loopGroups == undefined or loopGroups.count < 3 then undefined
            else
            (
                local blocked = #{}
                for gi in loopGroups do if gi > 0 and gi <= groups.count do blocked[gi] = true

                local seedFace = 0
                for gi in loopGroups while seedFace == 0 do
                (
                    if gi > 0 and gi <= groups.count do
                    (
                        for f in groups[gi][3] while seedFace == 0 do if comp[f] do seedFace = f
                    )
                )
                if seedFace == 0 then undefined
                else
                (
                    local faceAdj = #()
                    faceAdj.count = numFaces
                    for gi = 1 to groups.count do
                    (
                        if not blocked[gi] do
                        (
                            local g = groups[gi]
                            if g[3].count == 2 do
                            (
                                local f1 = g[3][1]
                                local f2 = g[3][2]
                                if comp[f1] and comp[f2] do
                                (
                                    if faceAdj[f1] == undefined do faceAdj[f1] = #{}
                                    if faceAdj[f2] == undefined do faceAdj[f2] = #{}
                                    faceAdj[f1][f2] = true
                                    faceAdj[f2][f1] = true
                                )
                            )
                        )
                    )

                    local sideA = #{}
                    local q = #(seedFace)
                    local qi = 1
                    sideA[seedFace] = true
                    while qi <= q.count do
                    (
                        local f = q[qi]
                        qi += 1
                        if faceAdj[f] != undefined do
                        (
                            for nf in faceAdj[f] do if comp[nf] and not sideA[nf] do
                            (
                                sideA[nf] = true
                                append q nf
                            )
                        )
                    )

                    local sideB = #{}
                    for f in comp do if not sideA[f] do sideB[f] = true
                    if sideA.isEmpty or sideB.isEmpty then undefined
                    else if sideA.numberSet <= sideB.numberSet then #(sideA, sideB) else #(sideB, sideA)
                )
            )
        )

        fn v71FacesTouchBoundary faceSet boundaryVerts faceGeom =
        (
            local touch = false
            if faceSet != undefined and boundaryVerts != undefined and not boundaryVerts.isEmpty do
            (
                for f in faceSet while not touch do
                (
                    if f > 0 and f <= faceGeom.count and faceGeom[f] != undefined do
                    (
                        for gv in faceGeom[f] while not touch do if gv > 0 and boundaryVerts[gv] do touch = true
                    )
                )
            )
            touch
        )

        fn v71FaceOverlapRatio a b =
        (
            if a == undefined or b == undefined or a.isEmpty or b.isEmpty then 0.0
            else
            (
                local overlap = 0
                for f in a do if b[f] do overlap += 1
                local denom = amin #(a.numberSet, b.numberSet)
                if denom < 1 then 0.0 else (overlap as float) / denom
            )
        )

        fn v71TerminalCandidateCompare a b =
        (
            if a[1] > b[1] then -1 else if a[1] < b[1] then 1 else 0
        )

        fn v71FindTerminalLoops comp groups faceGeom geomMesh maxGeomVert boundaryVerts vertGraph avgLen maxStretch seamWeight numFaces =
        (
            local accepted = #()
            if geomMesh == undefined or comp == undefined or comp.numberSet < 16 or boundaryVerts == undefined or boundaryVerts.isEmpty then return accepted

            local compVerts = v7ComponentVerts comp groups
            local vertGroups = v71BuildVertexGroups groups maxGeomVert comp
            local dj = v7DijkstraFromSet boundaryVerts vertGraph maxGeomVert
            local dists = dj[1]
            local maxD = 0.0
            for v in compVerts do if v > 0 and v <= dists.count and dists[v] < 1.0e29 and dists[v] > maxD do maxD = dists[v]
            if maxD <= 0.000001 then return accepted

            local candidates = #()
            local loopCovered = #{}
            local maxCapRatio = 0.30 - (0.10 * seamWeight)
            if maxCapRatio < 0.16 do maxCapRatio = 0.16
            local desiredRatio = 0.12 + ((maxStretch - 12.0) / 280.0)
            if desiredRatio < 0.08 do desiredRatio = 0.08
            if desiredRatio > 0.18 do desiredRatio = 0.18

            for seedGI = 1 to groups.count do
            (
                if not loopCovered[seedGI] and not groups[seedGI][6] and v71GroupInsideCount seedGI comp groups == 2 do
                (
                    local trace = v71TraceClosedLoop seedGI comp groups vertGroups geomMesh maxGeomVert
                    if trace != undefined do
                    (
                        local loopGroups = trace[1]
                        for gi in loopGroups do loopCovered[gi] = true

                        local split = v71SplitFacesByLoop comp loopGroups groups numFaces
                        if split != undefined do
                        (
                            local capFaces = split[1]
                            local capRatio = (capFaces.numberSet as float) / (comp.numberSet as float)
                            if capFaces.numberSet >= 3 and capRatio <= maxCapRatio and not v71FacesTouchBoundary capFaces boundaryVerts faceGeom do
                            (
                                local capVerts = v7ComponentVerts capFaces groups
                                local distSum = 0.0
                                local distCount = 0
                                for v in capVerts do if v > 0 and v <= dists.count and dists[v] < 1.0e29 do
                                (
                                    distSum += dists[v]
                                    distCount += 1
                                )
                                local distScore = if distCount > 0 then (distSum / distCount) / maxD else 0.0
                                if distScore > 1.0 do distScore = 1.0

                                local sizeScore = 1.0 - (abs(capRatio - desiredRatio) / desiredRatio)
                                if sizeScore < 0.0 do sizeScore = 0.0

                                local foldSum = 0.0
                                local loopLen = 0.0
                                for gi in loopGroups do
                                (
                                    foldSum += amin #(1.0, groups[gi][5] / 90.0)
                                    loopLen += groups[gi][8]
                                )
                                local foldScore = foldSum / loopGroups.count
                                local straightScore = trace[2]
                                if straightScore < 0.0 do straightScore = 0.0

                                local edgeCountPenalty = 0.12 * sqrt(loopGroups.count as float)
                                local score = (2.6 * distScore) + (1.5 * sizeScore) + (0.75 * straightScore) + (0.55 * foldScore) - edgeCountPenalty

                                -- A terminal loop must be strongly remote from an existing
                                -- open boundary. This is the key guard against arbitrary
                                -- circular cuts through the middle of smooth surfaces.
                                if distScore >= 0.48 and score >= 1.55 do append candidates #(score, loopGroups, capFaces, capRatio, distScore)
                            )
                        )
                    )
                )
            )

            if candidates.count > 1 do qsort candidates v71TerminalCandidateCompare

            local acceptedCaps = #()
            local maxLoops = 4
            for cand in candidates while accepted.count < maxLoops do
            (
                local overlaps = false
                for oldCap in acceptedCaps while not overlaps do if v71FaceOverlapRatio cand[3] oldCap > 0.35 do overlaps = true
                if not overlaps do
                (
                    append accepted cand
                    append acceptedCaps cand[3]
                )
            )
            accepted
        )


        ----------------------------------------------------------------------
        -- TOPOLOGY + EDGE-FLOW ATLAS V8
        --
        -- V8 adds a generic swept/strip detector before the V7.2 fallback.
        -- It does NOT identify semantic object types.  A component is treated
        -- as swept only when its geometry contains a strong dominant edge-flow
        -- axis and repeated longitudinal structure.
        --
        -- For swept components:
        --   * planar terminal/end faces are isolated with cap loops
        --   * hard-surface longitudinal feature rails are kept as seam chains
        --   * round/cylindrical cross-sections get ONE longitudinal opening rail
        --   * short local bevel/support edges are rejected by span filtering
        -- Components without strong swept structure use V7.2 unchanged.
        ----------------------------------------------------------------------

        fn v8GroupInsideComp gi comp groups =
        (
            local inside = false
            if gi > 0 and gi <= groups.count do
                for f in groups[gi][3] while not inside do if comp[f] do inside = true
            inside
        )

        fn v8GeomEdgeDir gi groups geomMesh =
        (
            local d = undefined
            if geomMesh != undefined and gi > 0 and gi <= groups.count do
            (
                local g = groups[gi]
                local nv = 0
                try(nv = getNumVerts geomMesh)catch(nv = 0)
                if g[1] > 0 and g[2] > 0 and g[1] <= nv and g[2] <= nv do
                (
                    local p1 = getVert geomMesh g[1]
                    local p2 = getVert geomMesh g[2]
                    local v = p2 - p1
                    if length v > 0.0000001 do d = normalize v
                )
            )
            d
        )

        fn v8ComponentAxisData comp groups geomMesh maxGeomVert =
        (
            if geomMesh == undefined or comp == undefined or comp.isEmpty then return undefined

            local seedGI = 0
            local seedLen = -1.0
            local totalLen = 0.0
            for gi = 1 to groups.count do if v8GroupInsideComp gi comp groups do
            (
                local gl = groups[gi][8]
                if gl > 0.0000001 do
                (
                    totalLen += gl
                    if gl > seedLen do
                    (
                        seedLen = gl
                        seedGI = gi
                    )
                )
            )
            if seedGI == 0 or totalLen <= 0.0000001 then return undefined

            local seedDir = v8GeomEdgeDir seedGI groups geomMesh
            if seedDir == undefined then return undefined

            local axisSum = [0,0,0]
            local coherentLen = 0.0
            for gi = 1 to groups.count do if v8GroupInsideComp gi comp groups do
            (
                local d = v8GeomEdgeDir gi groups geomMesh
                if d != undefined do
                (
                    local ad = abs(dot d seedDir)
                    if ad >= 0.70 do
                    (
                        if (dot d seedDir) < 0 do d = -d
                        local w = amax #(groups[gi][8], 0.0001)
                        axisSum += d * w
                        coherentLen += w
                    )
                )
            )
            if length axisSum <= 0.0000001 then return undefined
            local axis = normalize axisSum

            local alignedLen = 0.0
            local alignedCount = 0
            for gi = 1 to groups.count do if v8GroupInsideComp gi comp groups do
            (
                local d = v8GeomEdgeDir gi groups geomMesh
                if d != undefined and abs(dot d axis) >= 0.88 do
                (
                    alignedLen += amax #(groups[gi][8], 0.0)
                    alignedCount += 1
                )
            )
            local alignedRatio = if totalLen > 0.0000001 then alignedLen / totalLen else 0.0

            local compVerts = v7ComponentVerts comp groups
            local minP = 1.0e30
            local maxP = -1.0e30
            local nv = 0
            try(nv = getNumVerts geomMesh)catch(nv = 0)
            for v in compVerts do if v > 0 and v <= nv do
            (
                local pr = dot (getVert geomMesh v) axis
                if pr < minP do minP = pr
                if pr > maxP do maxP = pr
            )
            local span = maxP - minP
            if span <= 0.0000001 then return undefined

            -- Strong enough to be a repeated/swept surface.  The ratio is kept
            -- conservative so a teapot body or organic sculpt does not enter
            -- the strip branch just because it has a few long edges.
            local isSwept = (alignedCount >= 3 and alignedRatio >= 0.42)
            #(isSwept, axis, minP, maxP, span, alignedRatio, alignedCount)
        )

        fn v8FaceCentroidGeom f faceGeom geomMesh =
        (
            local c = [0,0,0]
            local cnt = 0
            if geomMesh != undefined and f > 0 and f <= faceGeom.count and faceGeom[f] != undefined do
            (
                local nv = 0
                try(nv = getNumVerts geomMesh)catch(nv = 0)
                for gv in faceGeom[f] do if gv > 0 and gv <= nv do
                (
                    c += getVert geomMesh gv
                    cnt += 1
                )
            )
            if cnt > 0 then c / cnt else undefined
        )

        fn v8FindEndCapFaces comp axis minP maxP faceGeom faceNormals geomMesh =
        (
            local minFaces = #{}
            local maxFaces = #{}
            local span = maxP - minP
            if span <= 0.0000001 then return #(minFaces,maxFaces)

            local band = span * 0.12
            for f in comp do
            (
                local c = v8FaceCentroidGeom f faceGeom geomMesh
                if c != undefined do
                (
                    local pr = dot c axis
                    local na = abs(dot faceNormals[f] axis)
                    if na >= 0.78 do
                    (
                        if pr <= (minP + band) do minFaces[f] = true
                        if pr >= (maxP - band) do maxFaces[f] = true
                    )
                )
            )
            #(minFaces,maxFaces)
        )

        fn v8CapBoundaryGroups capFaces comp groups =
        (
            local result = #{}
            if capFaces == undefined or capFaces.isEmpty then return result
            for gi = 1 to groups.count do
            (
                local inCap = 0
                local inComp = 0
                for f in groups[gi][3] do
                (
                    if comp[f] do inComp += 1
                    if capFaces[f] do inCap += 1
                )
                if inComp >= 1 and inCap >= 1 and inCap < inComp do result[gi] = true
            )
            result
        )

        fn v8GroupsToVerts groupSet groups =
        (
            local verts = #{}
            if groupSet != undefined do for gi in groupSet do if gi > 0 and gi <= groups.count do
            (
                verts[groups[gi][1]] = true
                verts[groups[gi][2]] = true
            )
            verts
        )

        fn v8VertSetRoundness verts axis geomMesh =
        (
            if verts == undefined or verts.numberSet < 6 or geomMesh == undefined then return 1.0
            local nv = 0
            try(nv = getNumVerts geomMesh)catch(nv = 0)
            local center = [0,0,0]
            local cnt = 0
            for v in verts do if v > 0 and v <= nv do
            (
                center += getVert geomMesh v
                cnt += 1
            )
            if cnt < 6 then return 1.0
            center /= cnt

            local avgR = 0.0
            local radii = #()
            for v in verts do if v > 0 and v <= nv do
            (
                local dv = (getVert geomMesh v) - center
                local axial = axis * (dot dv axis)
                local r = length (dv - axial)
                append radii r
                avgR += r
            )
            if radii.count < 6 then return 1.0
            avgR /= radii.count
            if avgR <= 0.0000001 then return 1.0

            local variance = 0.0
            for r in radii do variance += (r-avgR)*(r-avgR)
            variance /= radii.count
            (sqrt variance) / avgR
        )

        fn v8RailRecordCompare a b =
        (
            if a[1] > b[1] then -1 else if a[1] < b[1] then 1 else 0
        )

        fn v8FindStructuralRailChains comp groups geomMesh axis minP maxP capFaces avgLen seamWeight maxGeomVert =
        (
            local result = #()
            if geomMesh == undefined then return result
            local span = maxP - minP
            if span <= 0.0000001 then return result

            local hardMin = 30.0 + 15.0 * seamWeight
            local cand = #{}
            local vertToGroups = #()
            vertToGroups.count = maxGeomVert

            for gi = 1 to groups.count do if v8GroupInsideComp gi comp groups do
            (
                local g = groups[gi]
                local touchesCapInterior = false
                local sideFaceCount = 0
                for f in g[3] do if comp[f] do
                (
                    if capFaces != undefined and capFaces[f] then touchesCapInterior = true else sideFaceCount += 1
                )

                local d = v8GeomEdgeDir gi groups geomMesh
                if d != undefined and sideFaceCount > 0 and not g[6] and abs(dot d axis) >= 0.84 and g[5] >= hardMin do
                (
                    cand[gi] = true
                    local a = g[1]
                    local b = g[2]
                    if vertToGroups[a] == undefined do vertToGroups[a] = #()
                    if vertToGroups[b] == undefined do vertToGroups[b] = #()
                    append vertToGroups[a] gi
                    append vertToGroups[b] gi
                )
            )

            local seen = #{}
            local records = #()
            for seed in cand do if not seen[seed] do
            (
                local chain = #{}
                local q = #(seed)
                local qi = 1
                seen[seed] = true
                local cMin = 1.0e30
                local cMax = -1.0e30
                local foldSum = 0.0
                local ec = 0

                while qi <= q.count do
                (
                    local gi = q[qi]
                    qi += 1
                    chain[gi] = true
                    local g = groups[gi]
                    foldSum += g[5]
                    ec += 1

                    local nv = 0
                    try(nv = getNumVerts geomMesh)catch(nv = 0)
                    for v in #(g[1],g[2]) do if v > 0 and v <= nv do
                    (
                        local pr = dot (getVert geomMesh v) axis
                        if pr < cMin do cMin = pr
                        if pr > cMax do cMax = pr
                        if vertToGroups[v] != undefined do for ngi in vertToGroups[v] do if cand[ngi] and not seen[ngi] do
                        (
                            seen[ngi] = true
                            append q ngi
                        )
                    )
                )

                local chainSpan = cMax-cMin
                local spanRatio = chainSpan/span
                if ec > 0 and spanRatio >= 0.55 do
                (
                    local avgFold = foldSum/ec
                    local score = spanRatio * (1.0 + avgFold/90.0)
                    append records #(score,chain,spanRatio,avgFold)
                )
            )

            if records.count > 1 do qsort records v8RailRecordCompare
            local maxRails = 8
            for r in records while result.count < maxRails do append result r
            result
        )

        fn v8BuildComponentVertGraph comp groups avgLen seamWeight maxGeomVert protectedFaces =
        (
            local graph = #()
            graph.count = maxGeomVert
            for gi = 1 to groups.count do if v8GroupInsideComp gi comp groups do
            (
                local g = groups[gi]
                local fullyProtected = false
                if protectedFaces != undefined and not protectedFaces.isEmpty do
                (
                    local nInc = 0
                    local nProt = 0
                    for f in g[3] do if comp[f] do
                    (
                        nInc += 1
                        if protectedFaces[f] do nProt += 1
                    )
                    fullyProtected = (nInc > 0 and nProt == nInc)
                )

                if not fullyProtected do
                (
                    local a = g[1]
                    local b = g[2]
                    local lenN = if g[8] > 0.0000001 then g[8]/avgLen else 1.0
                    if lenN < 0.05 do lenN = 0.05
                    local fold = amin #(1.0,g[5]/90.0)
                    local cost = lenN * (1.0 - (0.18 + 0.35*(1.0-seamWeight))*fold)
                    if g[7] do cost *= 0.05
                    if g[6] do cost *= 0.02
                    if cost < 0.0001 do cost = 0.0001
                    if graph[a] == undefined do graph[a] = #()
                    if graph[b] == undefined do graph[b] = #()
                    append graph[a] #(b,gi,cost)
                    append graph[b] #(a,gi,cost)
                )
            )
            graph
        )

        fn v8TrySweptComponent comp groups faceGeom faceNormals geomMesh maxGeomVert avgLen maxStretch seamWeight numFaces candidateGroups =
        (
            local data = v8ComponentAxisData comp groups geomMesh maxGeomVert
            if data == undefined or not data[1] then return #(false,0,0,0)

            local axis = data[2]
            local minP = data[3]
            local maxP = data[4]
            local caps = v8FindEndCapFaces comp axis minP maxP faceGeom faceNormals geomMesh
            local capMin = caps[1]
            local capMax = caps[2]
            local capAll = copy capMin
            for f in capMax do capAll[f]=true

            local loopMin = v8CapBoundaryGroups capMin comp groups
            local loopMax = v8CapBoundaryGroups capMax comp groups
            local terminalLoops = 0
            local chains = 0

            if not loopMin.isEmpty do
            (
                local a = v7AppendPathGroups (loopMin as array) candidateGroups groups
                if a > 0 do
                (
                    chains += 1
                    terminalLoops += 1
                )
            )
            if not loopMax.isEmpty do
            (
                local a = v7AppendPathGroups (loopMax as array) candidateGroups groups
                if a > 0 do
                (
                    chains += 1
                    terminalLoops += 1
                )
            )

            local bData = v7BoundaryComponents comp groups maxGeomVert
            local bSets = bData[1]

            local endSetA = #{}
            local endSetB = #{}
            if not loopMin.isEmpty do endSetA = v8GroupsToVerts loopMin groups
            if not loopMax.isEmpty do endSetB = v8GroupsToVerts loopMax groups

            -- If a cap is absent, a true open boundary at that end becomes the
            -- corresponding free end set. Pick by average projection.
            if bSets.count > 0 do
            (
                local lowSet = undefined
                local highSet = undefined
                local lowP = 1.0e30
                local highP = -1.0e30
                local nv = 0
                try(nv=getNumVerts geomMesh)catch(nv=0)
                for bs in bSets do
                (
                    local sumP=0.0
                    local cnt=0
                    for v in bs do if v>0 and v<=nv do
                    (
                        sumP += dot (getVert geomMesh v) axis
                        cnt += 1
                    )
                    if cnt>0 do
                    (
                        local ap=sumP/cnt
                        if ap < lowP do
                        (
                            lowP = ap
                            lowSet = bs
                        )
                        if ap > highP do
                        (
                            highP = ap
                            highSet = bs
                        )
                    )
                )
                if endSetA.isEmpty and lowSet != undefined do endSetA = copy lowSet
                if endSetB.isEmpty and highSet != undefined do endSetB = copy highSet
            )

            local roundScore = 1.0
            if not loopMin.isEmpty then roundScore = amin #(roundScore, v8VertSetRoundness (v8GroupsToVerts loopMin groups) axis geomMesh)
            if not loopMax.isEmpty then roundScore = amin #(roundScore, v8VertSetRoundness (v8GroupsToVerts loopMax groups) axis geomMesh)
            if bSets.count > 0 do for bs in bSets do if bs.numberSet >= 6 do roundScore = amin #(roundScore, v8VertSetRoundness bs axis geomMesh)
            local roundLike = (roundScore <= 0.18)

            local rails = v8FindStructuralRailChains comp groups geomMesh axis minP maxP capAll avgLen seamWeight maxGeomVert

            if roundLike then
            (
                -- Round/tubular wall: never cut every longitudinal segment. One
                -- opening rail between the two end loops/boundaries is sufficient.
                if not endSetA.isEmpty and not endSetB.isEmpty do
                (
                    local sideGraph = v8BuildComponentVertGraph comp groups avgLen seamWeight maxGeomVert capAll
                    local pd = v7ShortestPathBetweenSets endSetA endSetB sideGraph maxGeomVert
                    if pd != undefined do
                    (
                        local a = v72AppendPathGroupsProtected pd[1] candidateGroups groups capAll #{}
                        if a > 0 do chains += 1
                    )
                )
            )
            else
            (
                -- Hard swept strip: accept only coherent high-dihedral rails that
                -- span most of the component. Local bevel/support fragments fail
                -- the span test and are ignored.
                for rr in rails do
                (
                    local a = v72AppendPathGroupsProtected (rr[2] as array) candidateGroups groups capAll #{}
                    if a > 0 do chains += 1
                )

                -- If no structural rail survived, still make one opening path
                -- between terminal/open end sets so the side wall can unfold.
                if rails.count == 0 and not endSetA.isEmpty and not endSetB.isEmpty do
                (
                    local sideGraph = v8BuildComponentVertGraph comp groups avgLen seamWeight maxGeomVert capAll
                    local pd = v7ShortestPathBetweenSets endSetA endSetB sideGraph maxGeomVert
                    if pd != undefined do
                    (
                        local a = v72AppendPathGroupsProtected pd[1] candidateGroups groups capAll #{}
                        if a > 0 do chains += 1
                    )
                )
            )

            #(true,chains,terminalLoops,(if roundLike then 1 else 2))
        )

        fn atlasBuildGeneral maxStretch seamWeight =
        (
            seamSuggestedUVEdges = #{}
            seamAnalysisValid = false
            seamAnalysisNode = undefined
            seamAnalysisFaceCount = 0
            seamTargetFaces = #{}
            seamTubeCount = 0
            seamManualCount = 0
            atlasChartCount = 0
            atlasWorstEnergy = 0.0

            if not ensureUnwrapReady() then return false

            local numFaces = 0
            try(numFaces = uv.numberPolygons())catch(numFaces = 0)
            if numFaces < 1 then
            (
                setStatus "Atlas V8: no faces."
                return false
            )

            local selectionData = getCurrentSelectionAsVertices()
            local targetFaces = getActiveSelectionFaces selectionData
            if targetFaces == undefined or targetFaces.isEmpty do targetFaces = getAllUVFaces()
            if targetFaces == undefined or targetFaces.isEmpty then
            (
                setStatus "Atlas V8: no target faces."
                return false
            )

            local node = activeUnwrapNode()
            local geomMesh = undefined
            try(if node != undefined do geomMesh = snapshotAsMesh node)catch(geomMesh = undefined)

            local faceGeom = #()
            faceGeom.count = numFaces
            local faceNormals = for f = 1 to numFaces collect [0,0,1]
            local edgeRecords = #()
            local maxGeomVert = 0

            for f = 1 to numFaces do
            (
                local n = [0,0,1]
                try(n = uv.getNormal f)catch(n = [0,0,1])
                if length n > 0.000001 then n = normalize n else n = [0,0,1]
                faceNormals[f] = n

                local np = 0
                try(np = uv.numberPointsInFace f)catch(np = 0)
                local gvs = #()
                local tvs = #()
                if np > 1 do
                (
                    for k = 1 to np do
                    (
                        local gv = 0
                        local tv = 0
                        try(gv = uv.getVertexGeomIndexFromFace f k)catch(gv = 0)
                        try(tv = uv.getVertexIndexFromFace f k)catch(tv = 0)
                        append gvs gv
                        append tvs tv
                        if gv > maxGeomVert do maxGeomVert = gv
                    )
                    for k = 1 to np do
                    (
                        local k2 = if k == np then 1 else k + 1
                        local g1 = gvs[k]
                        local g2 = gvs[k2]
                        local t1 = tvs[k]
                        local t2 = tvs[k2]
                        if g1 > 0 and g2 > 0 and g1 != g2 do
                        (
                            local glo = if g1 < g2 then g1 else g2
                            local ghi = if g1 < g2 then g2 else g1
                            local tlo = 0
                            local thi = 0
                            if t1 > 0 and t2 > 0 and t1 != t2 do
                            (
                                tlo = if t1 < t2 then t1 else t2
                                thi = if t1 < t2 then t2 else t1
                            )
                            append edgeRecords #(glo, ghi, f, tlo, thi)
                        )
                    )
                )
                faceGeom[f] = gvs
            )

            if edgeRecords.count < 1 or maxGeomVert < 1 then
            (
                if geomMesh != undefined do try(delete geomMesh)catch()
                if selectionData != undefined do restoreUVSelection selectionData
                setStatus "Atlas V8: geometry topology unavailable."
                return false
            )

            qsort edgeRecords seamEdgeRecordCompare

            -- Group: #(g1,g2,faces,tvPairs,dihedral,isTrueOpen,isExistingUVSeam,length)
            local groups = #()
            local i = 1
            while i <= edgeRecords.count do
            (
                local g1 = edgeRecords[i][1]
                local g2 = edgeRecords[i][2]
                local faces = #()
                local tvPairs = #()
                local j = i
                while j <= edgeRecords.count and edgeRecords[j][1] == g1 and edgeRecords[j][2] == g2 do
                (
                    append faces edgeRecords[j][3]
                    if edgeRecords[j][4] > 0 and edgeRecords[j][5] > 0 do append tvPairs #(edgeRecords[j][4], edgeRecords[j][5])
                    j += 1
                )

                local existing = false
                if tvPairs.count > 1 do
                (
                    local bp = tvPairs[1]
                    for q = 2 to tvPairs.count while not existing do
                        if tvPairs[q][1] != bp[1] or tvPairs[q][2] != bp[2] do existing = true
                )

                local ang = 0.0
                if faces.count > 1 do
                (
                    local dd = dot faceNormals[faces[1]] faceNormals[faces[2]]
                    if dd > 1.0 do dd = 1.0
                    if dd < -1.0 do dd = -1.0
                    ang = acos dd
                )

                append groups #(g1,g2,faces,tvPairs,ang,(faces.count == 1),existing,seamGeomEdgeLength g1 g2 geomMesh)
                i = j
            )

            -- Geometry face connectivity only. Existing UV seams do NOT split a
            -- geometry component; true open edges naturally have only one face.
            local faceAdj = for f = 1 to numFaces collect #{}
            for gi = 1 to groups.count do
            (
                local g = groups[gi]
                if g[3].count > 1 do
                (
                    local f1 = g[3][1]
                    local f2 = g[3][2]
                    if targetFaces[f1] and targetFaces[f2] do
                    (
                        faceAdj[f1][f2] = true
                        faceAdj[f2][f1] = true
                    )
                )
            )

            local components = #()
            local seenFaces = #{}
            for sf in targetFaces do if not seenFaces[sf] do
            (
                local comp = #{}
                local q = #(sf)
                local qi = 1
                seenFaces[sf] = true
                while qi <= q.count do
                (
                    local cf = q[qi]
                    qi += 1
                    comp[cf] = true
                    for nf in faceAdj[cf] do if targetFaces[nf] and not seenFaces[nf] do
                    (
                        seenFaces[nf] = true
                        append q nf
                    )
                )
                if not comp.isEmpty do append components comp
            )

            -- Intrinsic curvature is now ONLY a conservative trigger for one
            -- relief slit on an otherwise already-open disk-like component.
            -- It never creates rings/charts by itself.
            local faceCurv = for f = 1 to numFaces collect 0.0
            if geomMesh != undefined and maxGeomVert > 0 then
            (
                local angleSum = for v = 1 to maxGeomVert collect 0.0
                local incident = for v = 1 to maxGeomVert collect 0
                local globalBoundaryGV = #{}

                for gi = 1 to groups.count do
                (
                    local g = groups[gi]
                    if g[6] do
                    (
                        globalBoundaryGV[g[1]] = true
                        globalBoundaryGV[g[2]] = true
                    )
                )

                local nv = 0
                try(nv = getNumVerts geomMesh)catch(nv = 0)
                for f in targetFaces do
                (
                    local gvs = faceGeom[f]
                    if gvs != undefined and gvs.count >= 3 do
                    (
                        local np = gvs.count
                        for k = 1 to np do
                        (
                            local gp = gvs[if k == 1 then np else k - 1]
                            local gc = gvs[k]
                            local gn = gvs[if k == np then 1 else k + 1]
                            if gp > 0 and gc > 0 and gn > 0 and gp <= nv and gc <= nv and gn <= nv do
                            (
                                local pp = getVert geomMesh gp
                                local pc = getVert geomMesh gc
                                local pn = getVert geomMesh gn
                                local va = pp - pc
                                local vb = pn - pc
                                if length va > 0.0000001 and length vb > 0.0000001 do
                                (
                                    va = normalize va
                                    vb = normalize vb
                                    local dd = dot va vb
                                    if dd > 1.0 do dd = 1.0
                                    if dd < -1.0 do dd = -1.0
                                    angleSum[gc] += acos dd
                                    incident[gc] += 1
                                )
                            )
                        )
                    )
                )

                local vertCurv = for v = 1 to maxGeomVert collect 0.0
                for v = 1 to maxGeomVert do
                (
                    if incident[v] > 0 and not globalBoundaryGV[v] do
                        vertCurv[v] = abs(360.0 - angleSum[v]) / 360.0
                )

                for f in targetFaces do
                (
                    local gvs = faceGeom[f]
                    if gvs != undefined and gvs.count > 0 do
                    (
                        local sumC = 0.0
                        local cntC = 0
                        for gv in gvs do if gv > 0 and gv <= maxGeomVert do
                        (
                            sumC += vertCurv[gv]
                            cntC += 1
                        )
                        if cntC > 0 do faceCurv[f] = sumC / cntC
                    )
                )
            )

            local avgLen = 0.0
            local lenCount = 0
            for g in groups do if g[8] > 0.0000001 do
            (
                avgLen += g[8]
                lenCount += 1
            )
            if lenCount > 0 then avgLen /= lenCount else avgLen = 1.0

            local candidateGroups = #{}
            local totalChains = 0
            local totalTerminalLoops = 0
            local totalOpenBoundaries = 0
            local totalTrueOpenEdges = 0
            local worstEnergy = 0.0

            local totalSweptComponents = 0
            local totalRoundSwept = 0
            local totalHardSwept = 0

            for comp in components do
            (
                -- V8 first tries a topology/edge-flow interpretation. If the
                -- component is not strongly swept, the proven V7.2 logic below
                -- remains the fallback.
                local v8res = v8TrySweptComponent comp groups faceGeom faceNormals geomMesh maxGeomVert avgLen maxStretch seamWeight numFaces candidateGroups
                if v8res != undefined and v8res[1] then
                (
                    totalSweptComponents += 1
                    totalChains += v8res[2]
                    totalTerminalLoops += v8res[3]
                    if v8res[4] == 1 then totalRoundSwept += 1 else totalHardSwept += 1

                    local bd8 = v7BoundaryComponents comp groups maxGeomVert
                    totalOpenBoundaries += bd8[1].count
                    totalTrueOpenEdges += bd8[4]
                )
                else
                (
                    local compVerts = v7ComponentVerts comp groups
                    local boundaryData = v7BoundaryComponents comp groups maxGeomVert
                    local boundarySets = boundaryData[1]
                    local boundaryVerts = boundaryData[2]
                    totalOpenBoundaries += boundarySets.count
                    totalTrueOpenEdges += boundaryData[4]

                    -- Build a geometry-vertex graph for this component. The cost is
                    -- primarily geometric length. Existing seams/open borders are
                    -- nearly free. Folded edges are mildly preferred, never enough
                    -- to create the ring-cut explosion seen in V5/V6.
                    local vertGraph = #()
                    vertGraph.count = maxGeomVert
                    for gi = 1 to groups.count do
                    (
                        local g = groups[gi]
                        local inside = false
                        for f in g[3] while not inside do if comp[f] do inside = true
                        if inside do
                        (
                            local a = g[1]
                            local b = g[2]
                            local lenN = if g[8] > 0.0000001 then g[8] / avgLen else 1.0
                            if lenN < 0.05 do lenN = 0.05
                            local fold = amin #(1.0, g[5] / 90.0)
                            local foldBias = 0.15 + (0.55 * (1.0 - seamWeight))
                            local cost = lenN * (1.0 - foldBias * fold)
                            if g[7] do cost *= 0.05
                            if g[6] do cost *= 0.02
                            if cost < 0.0001 do cost = 0.0001

                            if vertGraph[a] == undefined do vertGraph[a] = #()
                            if vertGraph[b] == undefined do vertGraph[b] = #()
                            append vertGraph[a] #(b, gi, cost)
                            append vertGraph[b] #(a, gi, cost)
                        )
                    )

                    -- V7.2 ORDER: detect terminal caps FIRST. Their interior faces
                    -- are then protected before any longitudinal/relief path is added.
                    local protectedCapFaces = #{}
                    local terminalLoopGroups = #{}
                    local terminalLoops = v71FindTerminalLoops comp groups faceGeom geomMesh maxGeomVert boundaryVerts vertGraph avgLen maxStretch seamWeight numFaces
                    if terminalLoops != undefined do
                    (
                        for tc in terminalLoops do
                        (
                            for f in tc[3] do protectedCapFaces[f] = true
                            for gi in tc[2] do terminalLoopGroups[gi] = true

                            local addedLoop = v7AppendPathGroups tc[2] candidateGroups groups
                            if addedLoop > 0 do
                            (
                                totalChains += 1
                                totalTerminalLoops += 1
                            )
                        )
                    )

                    -- A) Multiple open boundary components: connect them with the
                    -- minimum number of open paths. Terminal-cap interiors are
                    -- forbidden, so a path can meet the separator but cannot cross it.
                    if boundarySets.count > 1 then
                    (
                        local rootSet = copy boundarySets[1]
                        for bi = 2 to boundarySets.count do
                        (
                            local pathData = v7ShortestPathBetweenSets rootSet boundarySets[bi] vertGraph maxGeomVert
                            if pathData != undefined do
                            (
                                local added = v72AppendPathGroupsProtected pathData[1] candidateGroups groups protectedCapFaces terminalLoopGroups
                                if added > 0 do totalChains += 1
                            )
                            for v in boundarySets[bi] do rootSet[v] = true
                        )
                    )
                    else if boundarySets.count == 0 then
                    (
                        -- B) Completely closed component: one conservative diameter
                        -- slit is the minimum starting cut. V7.2 still protects any
                        -- terminal regions if future closed-component detection adds them.
                        local dia = v7DiameterPath compVerts vertGraph maxGeomVert
                        if dia != undefined do
                        (
                            local added = v72AppendPathGroupsProtected dia[1] candidateGroups groups protectedCapFaces terminalLoopGroups
                            if added > 0 do totalChains += 1
                        )
                    )
                    else
                    (
                        -- C) One open boundary: add at most one relief slit. If its
                        -- farthest route enters a separated terminal cap, V7.2 clips
                        -- the interior portion so the seam ends at the cap loop.
                        local energy = 0.0
                        for f in comp do if not protectedCapFaces[f] do energy += faceCurv[f]
                        if energy > worstEnergy do worstEnergy = energy

                        local activeFaceCount = comp.numberSet - protectedCapFaces.numberSet
                        if activeFaceCount < 1 do activeFaceCount = comp.numberSet
                        local faceScale = sqrt (amax #(1.0, activeFaceCount as float))
                        local normalizedEnergy = energy / faceScale
                        local reliefThreshold = 0.020 + (maxStretch / 40.0) * 0.080 + seamWeight * 0.050

                        if activeFaceCount >= 12 and normalizedEnergy > reliefThreshold do
                        (
                            local relief = v7FarthestPathFromSet boundarySets[1] compVerts vertGraph maxGeomVert
                            if relief != undefined do
                            (
                                local added = v72AppendPathGroupsProtected relief[1] candidateGroups groups protectedCapFaces terminalLoopGroups
                                if added > 0 do totalChains += 1
                            )
                        )
                    )
                )
            )
            -- Convert geometry-edge seam chains to actual UV edge IDs.
            local candidateTVPairs = #()
            for gi in candidateGroups do for tp in groups[gi][4] do seamAppendUniquePair tp candidateTVPairs

            local allUVEdges = #{}
            try
            (
                uv.setTVSubObjectMode 3
                uv.selectFaces targetFaces
                uv.faceToEdgeSelect()
                allUVEdges = copy (uv.getSelectedEdges())
            )
            catch(allUVEdges = #{})

            if not allUVEdges.isEmpty and candidateTVPairs.count > 0 do
            (
                uv.setTVSubObjectMode 2
                for eid in allUVEdges do
                (
                    local edgeVerts = #()
                    try
                    (
                        uv.selectEdges #{eid}
                        uv.edgeToVertSelect()
                        edgeVerts = uv.getSelectedVertices() as array
                    )
                    catch(edgeVerts = #())
                    if edgeVerts.count == 2 do
                    (
                        local lo = if edgeVerts[1] < edgeVerts[2] then edgeVerts[1] else edgeVerts[2]
                        local hi = if edgeVerts[1] < edgeVerts[2] then edgeVerts[2] else edgeVerts[1]
                        if seamPairExists #(lo,hi) candidateTVPairs do seamSuggestedUVEdges[eid] = true
                    )
                )
            )

            if geomMesh != undefined do try(delete geomMesh)catch()
            if selectionData != undefined do restoreUVSelection selectionData

            seamAnalysisNode = node
            seamAnalysisFaceCount = numFaces
            seamTargetFaces = copy targetFaces
            seamAnalysisValid = true
            atlasChartCount = totalChains
            atlasWorstEnergy = worstEnergy

            if seamSuggestedUVEdges.isEmpty then
                setStatus ("Atlas V8: " + totalOpenBoundaries as string + " open set(s) | swept " + totalSweptComponents as string + " | no extra seam needed.")
            else
                setStatus ("Atlas V8: " + totalChains as string + " chains | " + totalTerminalLoops as string + " cap loop(s) | " + seamSuggestedUVEdges.numberSet as string + " edges | swept " + totalSweptComponents as string + " (round " + totalRoundSwept as string + ", hard " + totalHardSwept as string + ")")

            true
        )


        ----------------------------------------------------------------------
        -- NATIVE UNFOLD V2 - libigl LSCM + SLIM solver
        --
        -- This is deliberately separate from Auto Seam. Auto Seam remains the
        -- V2.1 feature-aware planner. Native Unfold reads the CURRENT applied
        -- Peel/Pelt seam set, cuts only along those seams / true open borders,
        -- solves each resulting chart, and reconstructs explicit shared TV
        -- topology from chart vertex IDs returned by RotateUV_Unfold.exe.
        ----------------------------------------------------------------------
        fn nativeUnfoldFindWorker =
        (
            local candidates = #()
            local srcFile = undefined
            try(srcFile = getSourceFileName())catch(srcFile = undefined)
            if srcFile != undefined and srcFile != "" do append candidates ((getFilenamePath srcFile) + "RotateUV_Unfold.exe")
            try(append candidates ((getDir #userScripts) + "\\RotateUVAtlas\\RotateUV_Unfold.exe"))catch()
            try(append candidates ((getDir #scripts) + "\\RotateUVAtlas\\RotateUV_Unfold.exe"))catch()
            for p in candidates do if p != undefined and doesFileExist p do return p
            undefined
        )

        fn nativeUnfoldCollectGeomSeams =
        (
            local peltEdges = #{}
            try(peltEdges = copy (uv.getPeltSelectedSeams()))catch(peltEdges = #{})
            if peltEdges == undefined or peltEdges.isEmpty then return #()

            local seamTVPairs = #()
            try
            (
                uv.setTVSubObjectMode 2
                for eid in peltEdges do
                (
                    local edgeVerts = #()
                    try
                    (
                        uv.selectEdges #{eid}
                        uv.edgeToVertSelect()
                        edgeVerts = uv.getSelectedVertices() as array
                    )
                    catch(edgeVerts = #())
                    if edgeVerts.count == 2 do
                    (
                        local tlo = if edgeVerts[1] < edgeVerts[2] then edgeVerts[1] else edgeVerts[2]
                        local thi = if edgeVerts[1] < edgeVerts[2] then edgeVerts[2] else edgeVerts[1]
                        seamAppendUniquePair #(tlo,thi) seamTVPairs
                    )
                )
            )
            catch()

            local geomPairs = #()
            local numFaces = 0
            try(numFaces = uv.numberPolygons())catch(numFaces = 0)
            if seamTVPairs.count > 0 do
            (
                for f = 1 to numFaces do
                (
                    local n = 0
                    try(n = uv.numberPointsInFace f)catch(n = 0)
                    if n > 1 do
                    (
                        for k = 1 to n do
                        (
                            local k2 = if k == n then 1 else k + 1
                            local tv1 = 0
                            local tv2 = 0
                            local g1 = 0
                            local g2 = 0
                            try(tv1 = uv.getVertexIndexFromFace f k)catch(tv1 = 0)
                            try(tv2 = uv.getVertexIndexFromFace f k2)catch(tv2 = 0)
                            if tv1 > 0 and tv2 > 0 and tv1 != tv2 do
                            (
                                local tlo = if tv1 < tv2 then tv1 else tv2
                                local thi = if tv1 < tv2 then tv2 else tv1
                                if seamPairExists #(tlo,thi) seamTVPairs do
                                (
                                    try(g1 = uv.getVertexGeomIndexFromFace f k)catch(g1 = 0)
                                    try(g2 = uv.getVertexGeomIndexFromFace f k2)catch(g2 = 0)
                                    if g1 > 0 and g2 > 0 and g1 != g2 do
                                    (
                                        local glo = if g1 < g2 then g1 else g2
                                        local ghi = if g1 < g2 then g2 else g1
                                        seamAppendUniquePair #(glo,ghi) geomPairs
                                    )
                                )
                            )
                        )
                    )
                )
            )
            geomPairs
        )

        fn nativeUnfoldExportInput outPath =
        (
            local node = activeUnwrapNode()
            if node == undefined then return #(false, "Select exactly one object with Unwrap UVW.", 0, 0, 0)

            local geomMesh = undefined
            try(geomMesh = snapshotAsMesh node)catch(geomMesh = undefined)
            if geomMesh == undefined then return #(false, "Could not snapshot geometry for Native Unfold.", 0, 0, 0)

            local numGeomVerts = 0
            local numFaces = 0
            try(numGeomVerts = getNumVerts geomMesh)catch(numGeomVerts = 0)
            try(numFaces = uv.numberPolygons())catch(numFaces = 0)
            if numGeomVerts < 3 or numFaces < 1 then
            (
                try(delete geomMesh)catch()
                return #(false, "Geometry contains no usable faces.", numGeomVerts, numFaces, 0)
            )

            local geomSeams = nativeUnfoldCollectGeomSeams()
            if geomSeams.count < 1 then
            (
                try(delete geomMesh)catch()
                return #(false, "No applied Peel/Pelt seams were found. Use Generate -> Preview -> Apply, or define seams manually first.", numGeomVerts, numFaces, 0)
            )

            local out = undefined
            try(out = createFile outPath)catch(out = undefined)
            if out == undefined then
            (
                try(delete geomMesh)catch()
                return #(false, "Could not create Native Unfold input file.", numGeomVerts, numFaces, geomSeams.count)
            )

            local ok = true
            local err = ""
            try
            (
                format "RUVUNFOLD 1\n" to:out
                format "VERTICES %\n" numGeomVerts to:out
                local tm = node.objectTransform
                for i = 1 to numGeomVerts do
                (
                    local p = (getVert geomMesh i) * tm
                    format "% % %\n" p.x p.y p.z to:out
                )

                format "FACES %\n" numFaces to:out
                for f = 1 to numFaces do
                (
                    local n = 0
                    try(n = uv.numberPointsInFace f)catch(n = 0)
                    if n < 3 then throw ("Unsupported face " + f as string + ": fewer than 3 corners.")
                    format "FACE % %" f n to:out
                    for k = 1 to n do
                    (
                        local gv = 0
                        try(gv = uv.getVertexGeomIndexFromFace f k)catch(gv = 0)
                        if gv < 1 or gv > numGeomVerts then throw ("Invalid geometry mapping at face " + f as string + ", corner " + k as string + ".")
                        format " %" gv to:out
                    )
                    format "\n" to:out
                )

                format "SEAMS %\n" geomSeams.count to:out
                for pair in geomSeams do format "SEAM % %\n" pair[1] pair[2] to:out
                format "END\n" to:out
            )
            catch
            (
                ok = false
                err = getCurrentException()
            )
            try(close out)catch()
            try(delete geomMesh)catch()
            #(ok, err, numGeomVerts, numFaces, geomSeams.count)
        )

        fn nativeUnfoldImportResult resultPath =
        (
            local inp = undefined
            try(inp = openFile resultPath)catch(inp = undefined)
            if inp == undefined then return #(false, "Native Unfold did not create a readable result.", 0, 0)

            local header = readLine inp
            if header != "RUVUV 1" then
            (
                try(close inp)catch()
                return #(false, "Invalid Native Unfold result header. Rebuild RotateUV_Unfold.exe.", 0, 0)
            )
            local statusLine = readLine inp
            if statusLine != "STATUS OK" then
            (
                try(close inp)catch()
                return #(false, "Native Unfold worker returned an error.", 0, 0)
            )

            local chartsLine = readLine inp
            local chartTok = if chartsLine != undefined then filterString chartsLine " \t" else #()
            if chartTok.count < 2 or chartTok[1] != "CHARTS" then
            (
                try(close inp)catch()
                return #(false, "Missing CHARTS record in Native Unfold result.", 0, 0)
            )
            local chartCount = chartTok[2] as integer

            local flipsLine = readLine inp
            local flipTok = if flipsLine != undefined then filterString flipsLine " \t" else #()
            local flipCount = 0
            if flipTok.count >= 2 and flipTok[1] == "FLIPS" do flipCount = flipTok[2] as integer

            local facesLine = readLine inp
            local faceTok = if facesLine != undefined then filterString facesLine " \t" else #()
            if faceTok.count < 2 or faceTok[1] != "FACES" then
            (
                try(close inp)catch()
                return #(false, "Missing FACES record in Native Unfold result.", chartCount, flipCount)
            )
            local resultFaceCount = faceTok[2] as integer
            local currentFaceCount = 0
            try(currentFaceCount = uv.numberPolygons())catch(currentFaceCount = 0)
            if resultFaceCount != currentFaceCount then
            (
                try(close inp)catch()
                return #(false, "Mesh topology changed while Native Unfold was running.", chartCount, flipCount)
            )

            local oldFaceSel = #{}
            try(oldFaceSel = copy (uv.getSelectedFaces()))catch(oldFaceSel = #{})
            local oldLock = undefined
            local oldElementMode = undefined
            try(oldLock = uv.getLock())catch(oldLock = undefined)
            try(oldElementMode = uv.getTVElementMode())catch(oldElementMode = undefined)

            local ok = true
            local err = ""
            try
            (
                undo "Native Unfold UVs" on
                (
                    try(uv.setLock false)catch()
                    try(uv.setTVElementMode false)catch()

                    local chartVertexIds = #()
                    local faceIds = #()
                    local cornerIds = #()
                    local createdTVIds = #()

                    for expectedFace = 1 to resultFaceCount do
                    (
                        local faceLine = readLine inp
                        local ft = if faceLine != undefined then filterString faceLine " \t" else #()
                        if ft.count < 3 or ft[1] != "FACE" then throw ("Malformed Native Unfold FACE record at face " + expectedFace as string + ".")
                        local faceIndex = ft[2] as integer
                        local n = ft[3] as integer
                        if faceIndex != expectedFace then throw "Native Unfold face ordering mismatch."
                        if (uv.numberPointsInFace faceIndex) != n then throw ("Native Unfold corner count mismatch at face " + faceIndex as string + ".")

                        for k = 1 to n do
                        (
                            local uvLine = readLine inp
                            local ut = if uvLine != undefined then filterString uvLine " \t" else #()
                            if ut.count < 5 or ut[1] != "UV" then throw ("Malformed Native Unfold UV record at face " + faceIndex as string + ".")
                            local cornerIndex = ut[2] as integer
                            if cornerIndex != k then throw "Native Unfold corner ordering mismatch."
                            local uVal = ut[3] as float
                            local vVal = ut[4] as float
                            local chartVertexId = ut[5] as integer

                            uv.setFaceVertex [uVal,vVal,0] faceIndex k false
                            local newTV = uv.getVertexIndexFromFace faceIndex k
                            append chartVertexIds chartVertexId
                            append faceIds faceIndex
                            append cornerIds k
                            append createdTVIds newTV
                        )
                        local endFace = readLine inp
                        if endFace != "END_FACE" then throw ("Missing END_FACE at face " + faceIndex as string + ".")
                    )

                    local maxChartVertexId = -1
                    for cv in chartVertexIds do if cv > maxChartVertexId do maxChartVertexId = cv
                    local chartToTV = #()
                    if maxChartVertexId >= 0 do chartToTV.count = maxChartVertexId + 1
                    for i = 1 to chartVertexIds.count do
                    (
                        local slot = chartVertexIds[i] + 1
                        local repTV = chartToTV[slot]
                        if repTV == undefined then
                            chartToTV[slot] = createdTVIds[i]
                        else
                            uv.setFaceVertexIndex faceIds[i] cornerIds[i] repTV
                    )

                    if oldElementMode != undefined do try(uv.setTVElementMode oldElementMode)catch()
                    if oldLock != undefined do try(uv.setLock oldLock)catch()
                    uv.setTVSubObjectMode 3
                    try(uv.selectFaces oldFaceSel)catch()
                    try(uv.updateMap())catch()
                    try(uv.invalidateView())catch()
                    try(redrawViews())catch()
                )
            )
            catch
            (
                ok = false
                err = getCurrentException()
                if oldElementMode != undefined do try(uv.setTVElementMode oldElementMode)catch()
                if oldLock != undefined do try(uv.setLock oldLock)catch()
            )
            try(close inp)catch()
            #(ok, err, chartCount, flipCount)
        )

        fn runNativeUnfold =
        (
            if isBusy then false
            else
            (
                isBusy = true
                uv = resolveUnwrap()
                local result = false
                local selectionData = undefined
                if ensureUnwrapReady() then
                (
                    selectionData = getCurrentSelectionAsVertices()
                    local worker = nativeUnfoldFindWorker()
                    if worker == undefined then
                    (
                        isBusy = false
                        if selectionData != undefined do restoreUVSelection selectionData
                        setStatus "Native Unfold worker not found; using Max Unfold3D."
                        return runUnfold3D optimizeOnly:false
                    )

                    local tempDir = (getDir #temp) + "\\RotateUVNativeUnfold\\"
                    makeDir tempDir all:true
                    local tag = (timestamp()) as string
                    local inPath = tempDir + "unfold_" + tag + ".ruvu"
                    local outPath = tempDir + "unfold_" + tag + ".ruvuv"
                    local logPath = tempDir + "unfold_" + tag + ".log"
                    setStatus "Native Unfold: exporting seam-constrained mesh..."
                    local exp = nativeUnfoldExportInput inPath
                    if not exp[1] then
                    (
                        messageBox ("Native Unfold export failed.\n\n" + exp[2]) title:"Rotate UV - Native Unfold"
                        setStatus "Native Unfold: export failed."
                    )
                    else
                    (
                        local exitCode = -1
                        local cmd = "\"" + worker + "\" \"" + inPath + "\" \"" + outPath + "\" > \"" + logPath + "\" 2>&1"
                        setStatus ("Native Unfold: solving " + exp[5] as string + " applied seams...")
                        try(HiddenDOSCommand cmd startpath:(getFilenamePath worker) prompt:"Rotate UV - Native Unfold..." exitCode:&exitCode)catch(exitCode = -999)
                        if exitCode != 0 or not doesFileExist outPath then
                        (
                            local detail = "Worker exit code: " + exitCode as string
                            if doesFileExist logPath do detail += "\n\nLog: " + logPath
                            messageBox ("Native Unfold failed.\n\n" + detail) title:"Rotate UV - Native Unfold"
                            setStatus "Native Unfold: worker failed."
                        )
                        else
                        (
                            local imported = nativeUnfoldImportResult outPath
                            if imported[1] then
                            (
                                result = true
                                local flipText = if imported[4] > 0 then (" | " + imported[4] as string + " flip warning") else ""
                                setStatus ("Native Unfold: " + imported[3] as string + " charts | LSCM + SLIM" + flipText)
                            )
                            else
                            (
                                messageBox ("Native Unfold result could not be applied.\n\n" + imported[2]) title:"Rotate UV - Native Unfold"
                                setStatus "Native Unfold: import failed."
                            )
                        )
                    )
                    try(deleteFile inPath)catch()
                    try(deleteFile outPath)catch()
                    if result do try(deleteFile logPath)catch()
                )
                if selectionData != undefined do restoreUVSelection selectionData
                isBusy = false
                result
            )
        )

        ----------------------------------------------------------------------
        -- NATIVE AUTO SEAM V2 - Feature-Aware native planner
        --
        -- The external worker receives only a temporary triangulated copy.
        -- It returns geometry-vertex PAIRS for structural seam edges selected by the native feature-aware planner.
        -- The Max model is never triangulated or modified by Generate/Preview.
        ----------------------------------------------------------------------
        fn nativeAutoSeamFindWorker =
        (
            local candidates = #()
            local srcFile = undefined
            try(srcFile = getSourceFileName())catch(srcFile = undefined)
            if srcFile != undefined and srcFile != "" do append candidates ((getFilenamePath srcFile) + "RotateUV_AutoSeam.exe")
            try(append candidates ((getDir #userScripts) + "\\RotateUVAtlas\\RotateUV_AutoSeam.exe"))catch()
            try(append candidates ((getDir #scripts) + "\\RotateUVAtlas\\RotateUV_AutoSeam.exe"))catch()
            for p in candidates do if p != undefined and doesFileExist p do return p
            undefined
        )

        fn nativeAutoSeamProfileBound =
        (
            case ddl_autoSeamProfile.selection of
            (
                1: 7.0
                2: 5.5
                3: 4.25
                4: 3.5
                default: 3.5
            )
        )

        fn nativeAutoSeamProfileName =
        (
            case ddl_autoSeamProfile.selection of
            (
                1: "Minimal Seams"
                2: "Balanced"
                3: "Low Distortion"
                4: "Ideal Standard"
                default: "Ideal Standard"
            )
        )

        fn nativeAutoSeamExportOBJ outPath =
        (
            local node = activeUnwrapNode()
            if node == undefined then return #(false, "Select exactly one object with Unwrap UVW.", 0, 0)

            local m = undefined
            try(m = snapshotAsMesh node)catch(m = undefined)
            if m == undefined then return #(false, "Could not create a temporary mesh snapshot.", 0, 0)

            local out = undefined
            try(out = createFile outPath)catch(out = undefined)
            if out == undefined then
            (
                try(delete m)catch()
                return #(false, "Could not create the temporary OBJ file.", 0, 0)
            )

            local nv = 0
            local nf = 0
            try(nv = getNumVerts m)catch(nv = 0)
            try(nf = getNumFaces m)catch(nf = 0)
            if nv < 3 or nf < 1 then
            (
                try(close out)catch()
                try(delete m)catch()
                return #(false, "The mesh has no usable triangles.", nv, nf)
            )

            try
            (
                for i = 1 to nv do
                (
                    local p = getVert m i
                    format "v % % %\n" p.x p.y p.z to:out
                )
                for f = 1 to nf do
                (
                    local tri = getFace m f
                    format "f % % %\n" (tri.x as integer) (tri.y as integer) (tri.z as integer) to:out
                )
            )
            catch
            (
                try(close out)catch()
                try(delete m)catch()
                return #(false, "Failed while writing temporary triangulated OBJ.", nv, nf)
            )

            try(close out)catch()
            try(delete m)catch()
            #(true, "", nv, nf)
        )

        fn nativeAutoSeamReadResult resultPath =
        (
            local inp = undefined
            try(inp = openFile resultPath)catch(inp = undefined)
            if inp == undefined then return #(false, "Native worker did not create a readable seam result.", #(), 0, 0, 0)

            local first = readLine inp
            local ft = if first != undefined then filterString first " \t" else #()
            if ft.count < 2 or ft[1] != "RUVSEAM" then
            (
                try(close inp)catch()
                return #(false, "Malformed native seam result header.", #(), 0, 0, 0)
            )

            local pairs = #()
            local components = 0
            local failedComponents = 0
            local unmatchedTriangles = 0
            while not (eof inp) do
            (
                local line = readLine inp
                if line != undefined do
                (
                    local t = filterString line " \t"
                    if t.count > 0 do
                    (
                        case t[1] of
                        (
                            "COMPONENTS": if t.count >= 2 do components = t[2] as integer
                            "FAILED_COMPONENTS": if t.count >= 2 do failedComponents = t[2] as integer
                            "UNMATCHED_TRIANGLES": if t.count >= 2 do unmatchedTriangles = t[2] as integer
                            "SEAM":
                            (
                                if t.count >= 3 do
                                (
                                    local a = t[2] as integer
                                    local b = t[3] as integer
                                    local lo = if a < b then a else b
                                    local hi = if a < b then b else a
                                    seamAppendUniquePair #(lo,hi) pairs
                                )
                            )
                        )
                    )
                )
            )
            try(close inp)catch()
            #(true, "", pairs, components, failedComponents, unmatchedTriangles)
        )

        fn nativeAutoSeamMapGeomPairs geomPairs =
        (
            seamSuggestedUVEdges = #{}
            if geomPairs == undefined or geomPairs.count < 1 then return 0

            local numFaces = 0
            try(numFaces = uv.numberPolygons())catch(numFaces = 0)
            if numFaces < 1 then return 0

            local targetFaces = #{}
            local candidateTVPairs = #()
            for f = 1 to numFaces do
            (
                targetFaces[f] = true
                local n = 0
                try(n = uv.numberPointsInFace f)catch(n = 0)
                if n > 1 do
                (
                    for k = 1 to n do
                    (
                        local k2 = if k == n then 1 else k + 1
                        local g1 = 0
                        local g2 = 0
                        local tv1 = 0
                        local tv2 = 0
                        try(g1 = uv.getVertexGeomIndexFromFace f k)catch(g1 = 0)
                        try(g2 = uv.getVertexGeomIndexFromFace f k2)catch(g2 = 0)
                        if g1 > 0 and g2 > 0 and g1 != g2 do
                        (
                            local glo = if g1 < g2 then g1 else g2
                            local ghi = if g1 < g2 then g2 else g1
                            if seamPairExists #(glo,ghi) geomPairs do
                            (
                                try(tv1 = uv.getVertexIndexFromFace f k)catch(tv1 = 0)
                                try(tv2 = uv.getVertexIndexFromFace f k2)catch(tv2 = 0)
                                if tv1 > 0 and tv2 > 0 and tv1 != tv2 do
                                (
                                    local tlo = if tv1 < tv2 then tv1 else tv2
                                    local thi = if tv1 < tv2 then tv2 else tv1
                                    seamAppendUniquePair #(tlo,thi) candidateTVPairs
                                )
                            )
                        )
                    )
                )
            )

            local allUVEdges = #{}
            try
            (
                uv.setTVSubObjectMode 3
                uv.selectFaces targetFaces
                uv.faceToEdgeSelect()
                allUVEdges = copy (uv.getSelectedEdges())
            )
            catch(allUVEdges = #{})

            if not allUVEdges.isEmpty and candidateTVPairs.count > 0 do
            (
                uv.setTVSubObjectMode 2
                for eid in allUVEdges do
                (
                    local edgeVerts = #()
                    try
                    (
                        uv.selectEdges #{eid}
                        uv.edgeToVertSelect()
                        edgeVerts = uv.getSelectedVertices() as array
                    )
                    catch(edgeVerts = #())
                    if edgeVerts.count == 2 do
                    (
                        local lo = if edgeVerts[1] < edgeVerts[2] then edgeVerts[1] else edgeVerts[2]
                        local hi = if edgeVerts[1] < edgeVerts[2] then edgeVerts[2] else edgeVerts[1]
                        if seamPairExists #(lo,hi) candidateTVPairs do seamSuggestedUVEdges[eid] = true
                    )
                )
            )

            seamTargetFaces = targetFaces
            seamSuggestedUVEdges.numberSet
        )

        fn runNativeAutoSeam =
        (
            if isBusy then false
            else
            (
                isBusy = true
                uv = resolveUnwrap()
                local result = false
                local selectionData = undefined

                if ensureUnwrapReady() then
                (
                    selectionData = getCurrentSelectionAsVertices()
                    local worker = nativeAutoSeamFindWorker()
                    if worker == undefined then
                    (
                        messageBox (
                            "RotateUV_AutoSeam.exe was not found.\n\n" +
                            "Build the supplied Native Auto Seam V2 GitHub project, then place RotateUV_AutoSeam.exe beside this .ms/.mcr file."
                        ) title:"Rotate UV - Native Auto Seam"
                        setStatus "AUTO SEAM: native worker not found."
                    )
                    else
                    (
                        local tempDir = (getDir #temp) + "\\RotateUVAutoSeam\\"
                        makeDir tempDir all:true
                        local tag = (timestamp()) as string
                        local inPath = tempDir + "seam_" + tag + ".obj"
                        local outPath = tempDir + "seam_" + tag + ".seams"
                        local logPath = tempDir + "seam_" + tag + ".log"

                        setStatus "AUTO SEAM: exporting temporary mesh..."
                        local exp = nativeAutoSeamExportOBJ inPath
                        if not exp[1] then
                        (
                            messageBox ("Auto Seam export failed.\n\n" + exp[2]) title:"Rotate UV - Native Auto Seam"
                            setStatus "AUTO SEAM: export failed."
                        )
                        else
                        (
                            local bound = nativeAutoSeamProfileBound()
                            local exitCode = -1
                            local cmd = "\"" + worker + "\" \"" + inPath + "\" \"" + outPath + "\" " + (bound as string) + " 1 > \"" + logPath + "\" 2>&1"
                            setStatus ("AUTO SEAM: planning structural seams | " + nativeAutoSeamProfileName())
                            try(HiddenDOSCommand cmd startpath:(getFilenamePath worker) prompt:"Rotate UV - optimizing native seams..." exitCode:&exitCode)catch(exitCode = -999)

                            if exitCode != 0 or not doesFileExist outPath then
                            (
                                local detail = "Worker exit code: " + exitCode as string
                                if doesFileExist logPath do detail += "\n\nLog: " + logPath
                                messageBox ("Native Auto Seam failed.\n\n" + detail) title:"Rotate UV - Native Auto Seam"
                                setStatus "AUTO SEAM: worker failed."
                            )
                            else
                            (
                                local parsed = nativeAutoSeamReadResult outPath
                                if parsed[1] then
                                (
                                    local mappedCount = nativeAutoSeamMapGeomPairs parsed[3]
                                    seamAnalysisNode = activeUnwrapNode()
                                    local nFaces = 0
                                    try(nFaces = uv.numberPolygons())catch(nFaces = 0)
                                    seamAnalysisFaceCount = nFaces
                                    seamAnalysisValid = true
                                    atlasChartCount = parsed[3].count
                                    atlasWorstEnergy = 0.0
                                    result = true

                                    local warn = ""
                                    if parsed[5] > 0 do warn += " | " + parsed[5] as string + " component fail"
                                    if parsed[6] > 0 do warn += " | " + parsed[6] as string + " unmatched tri"
                                    setStatus ("AUTO SEAM: " + mappedCount as string + " Max edges | " + parsed[3].count as string + " cuts | " + nativeAutoSeamProfileName() + warn)
                                )
                                else
                                (
                                    messageBox ("Auto Seam result could not be read.\n\n" + parsed[2]) title:"Rotate UV - Native Auto Seam"
                                    setStatus "AUTO SEAM: result parse failed."
                                )
                            )
                        )

                        try(deleteFile inPath)catch()
                        try(deleteFile outPath)catch()
                        if result do try(deleteFile logPath)catch()
                    )
                )

                if selectionData != undefined do restoreUVSelection selectionData
                isBusy = false
                result
            )
        )

        fn seamAnalyze =
        (
            runNativeAutoSeam()
        )

        fn seamPreview =
        (
            local node = activeUnwrapNode()
            if not seamAnalysisValid or seamAnalysisNode != node then
            (
                setStatus "AUTO SEAM: Generate first."
                false
            )
            else if seamSuggestedUVEdges.isEmpty then
            (
                setStatus "AUTO SEAM: no proposed edges."
                false
            )
            else if not ensureUnwrapReady() then false
            else
            (
                local ok = true
                try
                (
                    uv.setTVSubObjectMode 2
                    uv.selectEdges seamSuggestedUVEdges
                    try(uv.setPeltAlwaysShowSeams true)catch()
                )
                catch(ok = false)
                if ok then setStatus ("Preview: " + seamSuggestedUVEdges.numberSet as string + " seam edges | native optimized proposal.")
                else setStatus "Preview failed."
                ok
            )
        )

        fn seamApply =
        (
            local node = activeUnwrapNode()
            if not seamAnalysisValid or seamAnalysisNode != node then
            (
                setStatus "AUTO SEAM: Generate first."
                false
            )
            else if seamSuggestedUVEdges.isEmpty then
            (
                setStatus "AUTO SEAM: nothing to apply."
                false
            )
            else if not ensureUnwrapReady() then false
            else
            (
                local ok = true
                undo "Apply Auto Seams" on
                (
                    try
                    (
                        uv.setTVSubObjectMode 2
                        uv.selectEdges seamSuggestedUVEdges
                        try(uv.syncGeomSelection())catch()
                        uv.peltEdgeSelToSeam false
                        try(uv.setPeltAlwaysShowSeams true)catch()
                        try(uv.updateMap())catch()
                        try(uv.invalidateView())catch()
                    )
                    catch(ok = false)
                )
                if ok then setStatus ("Applied " + seamSuggestedUVEdges.numberSet as string + " native seam edges. Now press Unfold.")
                else
                (
                    setStatus "Apply seams failed."
                    messageBox "The proposed edges were selected, but 3ds Max did not accept Convert Edge Selection To Seams in the current modifier state." title:"Rotate UV - Native Auto Seam"
                )
                ok
            )
        )

        ----------------------------------------------------------------------
        -- PRO QUAD-GRID STRAIGHTENER
        --
        -- A valid patch must be topologically rectangular:
        --   * quads only
        --   * one simple boundary loop
        --   * exactly four grid corners
        --   * opposite boundary sides have matching segment counts
        --
        -- The target grid is axis-aligned, but row/column spacing is derived
        -- from corresponding 3D edge lengths when geometry lookup is available.
        -- Total current UV area is preserved approximately, so Straighten does
        -- not arbitrarily normalize the shell scale / texel density.
        ----------------------------------------------------------------------

        fn splitFaceSelectionUVComponents faceSel =
        (
            local components = #()
            if faceSel == undefined or faceSel.isEmpty then return components

            local numFaces = 0
            try(numFaces = uv.numberPolygons())catch(numFaces = 0)
            if numFaces < 1 then return components

            local faceAdj = for i = 1 to numFaces collect #{}
            local edgeRecords = #()

            for f in faceSel do
            (
                local nPts = 0
                try(nPts = uv.numberPointsInFace f)catch(nPts = 0)
                if nPts > 1 do
                (
                    local tvs = #()
                    for k = 1 to nPts do
                    (
                        local tv = 0
                        try(tv = uv.getVertexIndexFromFace f k)catch(tv = 0)
                        append tvs tv
                    )

                    for k = 1 to tvs.count do
                    (
                        local a = tvs[k]
                        local b = tvs[if k == tvs.count then 1 else k + 1]
                        if a > 0 and b > 0 and a != b do
                        (
                            local lo = if a < b then a else b
                            local hi = if a < b then b else a
                            append edgeRecords #(lo, hi, f)
                        )
                    )
                )
            )

            if edgeRecords.count > 0 do
            (
                qsort edgeRecords uvEdgeRecordCompare
                local i = 1
                while i <= edgeRecords.count do
                (
                    local lo = edgeRecords[i][1]
                    local hi = edgeRecords[i][2]
                    local j = i + 1
                    while j <= edgeRecords.count and edgeRecords[j][1] == lo and edgeRecords[j][2] == hi do j += 1

                    if (j - i) > 1 do
                    (
                        local baseFace = edgeRecords[i][3]
                        local r = i + 1
                        while r < j do
                        (
                            local otherFace = edgeRecords[r][3]
                            if otherFace != baseFace do
                            (
                                faceAdj[baseFace][otherFace] = true
                                faceAdj[otherFace][baseFace] = true
                            )
                            r += 1
                        )
                    )
                    i = j
                )
            )

            local visited = #{}
            for startFace in faceSel do
            (
                if not visited[startFace] do
                (
                    local queue = #(startFace)
                    local qi = 1
                    local comp = #{}
                    visited[startFace] = true

                    while qi <= queue.count do
                    (
                        local f = queue[qi]
                        qi += 1
                        comp[f] = true

                        for n in faceAdj[f] do
                        (
                            if faceSel[n] and not visited[n] do
                            (
                                visited[n] = true
                                append queue n
                            )
                        )
                    )
                    if not comp.isEmpty do append components comp
                )
            )
            components
        )

        fn gridGraphDistances startVert patchVerts vertAdj numVerts =
        (
            local dist = #()
            dist.count = numVerts
            local queue = #(startVert)
            local qi = 1
            dist[startVert] = 0

            while qi <= queue.count do
            (
                local v = queue[qi]
                qi += 1
                local nextD = dist[v] + 1
                if vertAdj[v] != undefined do
                (
                    for n in vertAdj[v] do
                    (
                        if patchVerts[n] and dist[n] == undefined do
                        (
                            dist[n] = nextD
                            append queue n
                        )
                    )
                )
            )
            dist
        )

        fn uvPolygonAreaFromTVs tvs =
        (
            if tvs == undefined or tvs.count < 3 then 0.0
            else
            (
                local sum = 0.0
                for k = 1 to tvs.count do
                (
                    local a = undefined
                    local b = undefined
                    try(a = uv.getVertexPosition 0 tvs[k])catch(a = undefined)
                    try(b = uv.getVertexPosition 0 tvs[if k == tvs.count then 1 else k + 1])catch(b = undefined)
                    if a != undefined and b != undefined do sum += (a.x * b.y) - (b.x * a.y)
                )
                abs(sum * 0.5)
            )
        )

        fn metricEdgeLength tvA tvB tvGeom geomMesh geomTM =
        (
            -- Prefer the real 3D edge length, but NEVER let a geometry lookup
            -- failure abort Straighten.  If anything is unavailable, fall back
            -- to the current UV edge length.
            local len = 0.0
            local usedGeom = false

            try
            (
                if geomMesh != undefined and tvGeom != undefined and
                   tvA >= 1 and tvB >= 1 and tvA <= tvGeom.count and tvB <= tvGeom.count do
                (
                    local gA = tvGeom[tvA]
                    local gB = tvGeom[tvB]
                    local meshVertCount = 0

                    -- Correct TriMesh vertex-count access for 3ds Max.
                    try(meshVertCount = getNumVerts geomMesh)
                    catch(try(meshVertCount = geomMesh.numverts)catch(meshVertCount = 0))

                    if gA != undefined and gB != undefined and
                       gA > 0 and gB > 0 and
                       meshVertCount > 0 and gA <= meshVertCount and gB <= meshVertCount do
                    (
                        try
                        (
                            local pA = getVert geomMesh gA
                            local pB = getVert geomMesh gB
                            if geomTM != undefined do
                            (
                                pA = pA * geomTM
                                pB = pB * geomTM
                            )
                            len = distance pA pB
                            usedGeom = len > 0.00000001
                        )
                        catch(usedGeom = false)
                    )
                )
            )
            catch(usedGeom = false)

            if not usedGeom do
            (
                local p1 = undefined
                local p2 = undefined
                try(p1 = uv.getVertexPosition 0 tvA)catch(p1 = undefined)
                try(p2 = uv.getVertexPosition 0 tvB)catch(p2 = undefined)
                if p1 != undefined and p2 != undefined do len = distance p1 p2
            )
            len
        )

        fn buildRectangularQuadGrid faceSel =
        (
            if faceSel == undefined or faceSel.isEmpty then return undefined

            local numVerts = 0
            try(numVerts = uv.NumberVertices())catch(numVerts = 0)
            if numVerts < 1 then return undefined

            local vertAdj = #()
            local boundaryAdj = #()
            local tvGeom = #()
            vertAdj.count = numVerts
            boundaryAdj.count = numVerts
            tvGeom.count = numVerts

            local patchVerts = #{}
            local edgeRecords = #()
            local faceTVs = #()
            local totalUVArea = 0.0

            for f in faceSel do
            (
                local nPts = 0
                try(nPts = uv.numberPointsInFace f)catch(nPts = 0)
                if nPts != 4 then return undefined

                local tvs = #()
                local geoms = #()
                for k = 1 to 4 do
                (
                    local tv = 0
                    local gv = 0
                    try(tv = uv.getVertexIndexFromFace f k)catch(tv = 0)
                    try(gv = uv.getVertexGeomIndexFromFace f k)catch(gv = 0)
                    if tv < 1 or tv > numVerts then return undefined
                    append tvs tv
                    append geoms gv
                    patchVerts[tv] = true
                    if gv > 0 and tvGeom[tv] == undefined do tvGeom[tv] = gv
                )
                append faceTVs tvs
                totalUVArea += uvPolygonAreaFromTVs tvs

                for k = 1 to 4 do
                (
                    local a = tvs[k]
                    local b = tvs[if k == 4 then 1 else k + 1]
                    if a == b then return undefined

                    if vertAdj[a] == undefined do vertAdj[a] = #{}
                    if vertAdj[b] == undefined do vertAdj[b] = #{}
                    vertAdj[a][b] = true
                    vertAdj[b][a] = true

                    local lo = if a < b then a else b
                    local hi = if a < b then b else a
                    append edgeRecords #(lo, hi, f)
                )
            )

            if edgeRecords.count < 4 then return undefined
            qsort edgeRecords uvEdgeRecordCompare

            local boundaryEdges = #()
            local i = 1
            while i <= edgeRecords.count do
            (
                local lo = edgeRecords[i][1]
                local hi = edgeRecords[i][2]
                local j = i + 1
                while j <= edgeRecords.count and edgeRecords[j][1] == lo and edgeRecords[j][2] == hi do j += 1
                local countSame = j - i

                if countSame == 1 then
                (
                    append boundaryEdges #(lo, hi)
                    if boundaryAdj[lo] == undefined do boundaryAdj[lo] = #{}
                    if boundaryAdj[hi] == undefined do boundaryAdj[hi] = #{}
                    boundaryAdj[lo][hi] = true
                    boundaryAdj[hi][lo] = true
                )
                else if countSame != 2 then
                (
                    return undefined
                )
                i = j
            )

            if boundaryEdges.count < 4 then return undefined

            local corners = #()
            for v in patchVerts do
            (
                local d = if vertAdj[v] == undefined then 0 else vertAdj[v].numberSet
                if d < 2 or d > 4 then return undefined
                if d == 2 do append corners v
            )
            if corners.count != 4 then return undefined

            -- Every boundary vertex must have exactly two boundary neighbors.
            for pair in boundaryEdges do
            (
                local a = pair[1]
                local b = pair[2]
                if boundaryAdj[a] == undefined or boundaryAdj[b] == undefined then return undefined
            )
            for v in patchVerts do
            (
                if boundaryAdj[v] != undefined and boundaryAdj[v].numberSet != 2 then return undefined
            )

            -- Trace the single boundary loop, starting at a corner.
            local startV = corners[1]
            local boundaryLoop = #(startV)
            local prevV = 0
            local curV = startV
            local safety = 0
            local closed = false

            while not closed and safety < (boundaryEdges.count + 4) do
            (
                safety += 1
                local nextV = 0
                for n in boundaryAdj[curV] while nextV == 0 do
                (
                    if n != prevV do nextV = n
                )
                if nextV == 0 then return undefined

                if nextV == startV then
                (
                    closed = true
                )
                else
                (
                    append boundaryLoop nextV
                    prevV = curV
                    curV = nextV
                )
            )
            if not closed or boundaryLoop.count != boundaryEdges.count then return undefined

            local cornerPos = #()
            for idx = 1 to boundaryLoop.count do
            (
                if (findItem corners boundaryLoop[idx]) > 0 do append cornerPos idx
            )
            if cornerPos.count != 4 or cornerPos[1] != 1 then return undefined

            local s1 = cornerPos[2] - cornerPos[1]
            local s2 = cornerPos[3] - cornerPos[2]
            local s3 = cornerPos[4] - cornerPos[3]
            local s4 = boundaryLoop.count - cornerPos[4] + cornerPos[1]
            if s1 < 1 or s2 < 1 or s1 != s3 or s2 != s4 then return undefined

            local A = boundaryLoop[cornerPos[1]]
            local B = boundaryLoop[cornerPos[2]]
            local C = boundaryLoop[cornerPos[3]]
            local D = boundaryLoop[cornerPos[4]]
            local W = s1
            local H = s4

            local dA = gridGraphDistances A patchVerts vertAdj numVerts
            local dB = gridGraphDistances B patchVerts vertAdj numVerts
            local dD = gridGraphDistances D patchVerts vertAdj numVerts

            local coords = #()
            coords.count = numVerts
            local cellToVert = #()
            cellToVert.count = (W + 1) * (H + 1)
            local cells = #{}

            for v in patchVerts do
            (
                if dA[v] == undefined or dB[v] == undefined or dD[v] == undefined then return undefined

                local rawI = (dA[v] - dB[v] + W) / 2.0
                local rawJ = (dA[v] - dD[v] + H) / 2.0
                local ii = floor(rawI + 0.5)
                local jj = floor(rawJ + 0.5)

                if abs(rawI - ii) > 0.001 or abs(rawJ - jj) > 0.001 then return undefined
                if ii < 0 or ii > W or jj < 0 or jj > H then return undefined

                local cellIndex = (jj * (W + 1)) + ii + 1
                if cells[cellIndex] then return undefined
                cells[cellIndex] = true
                cellToVert[cellIndex] = v
                coords[v] = [ii, jj, 0]
            )

            if patchVerts.numberSet != ((W + 1) * (H + 1)) or cells.numberSet != patchVerts.numberSet then return undefined

            #(patchVerts, faceSel, W, H, coords, cellToVert, tvGeom, totalUVArea, A, B, C, D)
        )

        fn rectangularizeQuadGrid faceSel =
        (
            local grid = buildRectangularQuadGrid faceSel
            if grid == undefined then return false

            local patchVerts = grid[1]
            local W = grid[3]
            local H = grid[4]
            local coords = grid[5]
            local cellToVert = grid[6]
            local tvGeom = grid[7]
            local totalUVArea = grid[8]
            local A = grid[9]
            local B = grid[10]
            local D = grid[12]

            local node = activeUnwrapNode()
            local geomMesh = undefined
            local geomTM = undefined
            if node != undefined do
            (
                try(geomMesh = snapshotAsMesh node)catch(geomMesh = undefined)
                try(geomTM = node.objectTransform)catch(geomTM = undefined)
            )

            local uLens = #()
            local vLens = #()

            for ii = 0 to (W - 1) do
            (
                local total = 0.0
                local count = 0
                for jj = 0 to H do
                (
                    local idx1 = (jj * (W + 1)) + ii + 1
                    local idx2 = idx1 + 1
                    local v1 = cellToVert[idx1]
                    local v2 = cellToVert[idx2]
                    if v1 != undefined and v2 != undefined do
                    (
                        local len = metricEdgeLength v1 v2 tvGeom geomMesh geomTM
                        if len > 0.00000001 do
                        (
                            total += len
                            count += 1
                        )
                    )
                )
                append uLens (if count > 0 then total / count else 1.0)
            )

            for jj = 0 to (H - 1) do
            (
                local total = 0.0
                local count = 0
                for ii = 0 to W do
                (
                    local idx1 = (jj * (W + 1)) + ii + 1
                    local idx2 = idx1 + (W + 1)
                    local v1 = cellToVert[idx1]
                    local v2 = cellToVert[idx2]
                    if v1 != undefined and v2 != undefined do
                    (
                        local len = metricEdgeLength v1 v2 tvGeom geomMesh geomTM
                        if len > 0.00000001 do
                        (
                            total += len
                            count += 1
                        )
                    )
                )
                append vLens (if count > 0 then total / count else 1.0)
            )

            local uCum = #(0.0)
            local vCum = #(0.0)
            for len in uLens do append uCum (uCum[uCum.count] + len)
            for len in vLens do append vCum (vCum[vCum.count] + len)

            local rawW = uCum[uCum.count]
            local rawH = vCum[vCum.count]
            if rawW <= 0.00000001 or rawH <= 0.00000001 then return false

            -- Preserve the patch's current UV area while adopting 3D-proportional
            -- row / column spacing. This keeps scale much more stable than forcing
            -- the raw world dimensions directly into UV space.
            local scale = 1.0
            if totalUVArea > 0.00000001 do scale = sqrt(totalUVArea / (rawW * rawH))
            for i = 1 to uCum.count do uCum[i] *= scale
            for i = 1 to vCum.count do vCum[i] *= scale

            local targetW = uCum[uCum.count]
            local targetH = vCum[vCum.count]
            local oldCenter = centerFromVerts patchVerts
            if oldCenter == undefined then return false

            local pA = uv.getVertexPosition 0 A
            local pB = uv.getVertexPosition 0 B
            local pD = uv.getVertexPosition 0 D
            local vecU = pB - pA
            local vecV = pD - pA

            -- Keep the grid's existing broad orientation: whichever topological
            -- axis already points more horizontally remains the horizontal axis.
            local uIsHorizontal = (abs vecU.x >= abs vecU.y)
            local signX = 1.0
            local signY = 1.0

            if uIsHorizontal then
            (
                if vecU.x < 0 do signX = -1.0
                if vecV.y < 0 do signY = -1.0
            )
            else
            (
                if vecV.x < 0 do signX = -1.0
                if vecU.y < 0 do signY = -1.0
            )

            local ok = true
            try
            (
                for v in patchVerts do
                (
                    local c = coords[v]
                    local ii = c.x as integer
                    local jj = c.y as integer
                    local oldP = uv.getVertexPosition 0 v
                    local newX = oldCenter.x
                    local newY = oldCenter.y

                    if uIsHorizontal then
                    (
                        newX = oldCenter.x + signX * (uCum[ii + 1] - (targetW * 0.5))
                        newY = oldCenter.y + signY * (vCum[jj + 1] - (targetH * 0.5))
                    )
                    else
                    (
                        newX = oldCenter.x + signX * (vCum[jj + 1] - (targetH * 0.5))
                        newY = oldCenter.y + signY * (uCum[ii + 1] - (targetW * 0.5))
                    )

                    uv.SetVertexPosition 0 v [newX, newY, oldP.z]
                )
            )
            catch(ok = false)

            ok
        )

        fn runStraightenUV =
        (
            if isBusy then false
            else
            (
                isBusy = true
                uv = resolveUnwrap()
                local result = false
                local selectionData = undefined

                if ensureUnwrapReady() then
                (
                    selectionData = getCurrentSelectionAsVertices()
                    local faceSel = getActiveSelectionFaces selectionData

                    if faceSel == undefined or faceSel.isEmpty then
                    (
                        setStatus "Straighten UV: select a quad-grid UV patch first."
                    )
                    else
                    (
                        local components = splitFaceSelectionUVComponents faceSel
                        local successCount = 0
                        local skippedCount = 0

                        undo "Straighten UV Grid" on
                        (
                            for comp in components do
                            (
                                local compOK = false
                                try(compOK = rectangularizeQuadGrid comp)catch(compOK = false)
                                if compOK then successCount += 1 else skippedCount += 1
                            )
                            restoreUVSelection selectionData
                            try(uv.updateMap())catch()
                            try(uv.invalidateView())catch()
                            try(redrawViews())catch()
                        )

                        result = successCount > 0
                        setStatus ("Straighten UV: " + (successCount as string) + " grid patch(es) | " + (skippedCount as string) + " skipped (non-grid).")

                        if successCount == 0 do
                        (
                            messageBox "Straighten UV requires a rectangular quad-grid patch.\n\nThe selected UV faces must form one or more clean quad grids with four logical corners. Triangular, radial, branched or irregular topology is left unchanged." title:"Rotate UV - Straighten"
                        )
                    )
                )

                if selectionData != undefined do restoreUVSelection selectionData
                isBusy = false
                result
            )
        )

        fn runStraightenShell =
        (
            if isBusy then false
            else
            (
                isBusy = true
                uv = resolveUnwrap()
                local result = false
                local selectionData = undefined

                if ensureUnwrapReady() then
                (
                    selectionData = getCurrentSelectionAsVertices()
                    local targetIslands = getUnfoldTargetIslands selectionData
                    local scopeText = selectionScopeLabel selectionData

                    if targetIslands.count < 1 then
                    (
                        setStatus "Straighten Shell: no UV shells found."
                    )
                    else
                    (
                        local successCount = 0
                        local skippedCount = 0

                        undo "Straighten UV Shells" on
                        (
                            for islandData in targetIslands do
                            (
                                local shellOK = false
                                try(shellOK = rectangularizeQuadGrid islandData[3])catch(shellOK = false)
                                if shellOK then successCount += 1 else skippedCount += 1
                            )

                            restoreUVSelection selectionData
                            try(uv.updateMap())catch()
                            try(uv.invalidateView())catch()
                            try(redrawViews())catch()
                        )

                        result = successCount > 0
                        setStatus ("Straighten Shell: " + (successCount as string) + "/" + (targetIslands.count as string) + " " + scopeText + " rectangular grid shells | " + (skippedCount as string) + " skipped.")
                    )
                )

                if selectionData != undefined do restoreUVSelection selectionData
                isBusy = false
                result
            )
        )

        ----------------------------------------------------------------------
        ----------------------------------------------------------------------
        -- Events
        ----------------------------------------------------------------------
        on chk_capture changed state do
        (
            if state then
            (
                if not captureIslands() do chk_capture.state = false
            )
            else
            (
                if not isBusy do
                (
                    clearCapture updateButton:false
                    setStatus "Capture cleared."
                )
            )
        )

        on rb_workMode changed newState do
        (
            if chk_capture.state do
            (
                clearCapture()
                setStatus "Mode changed - capture islands again."
            )
        )

        on btn_alignHoriz pressed do alignCurrentSelection #horizontal
        on btn_alignVert pressed do alignCurrentSelection #vertical

        on btn_arrangeHoriz pressed do arrangeAllUVIslands #horizontal
        on btn_arrangeVert pressed do arrangeAllUVIslands #vertical
        on btn_compactH pressed do arrangeCompactBlock #horizontal
        on btn_compactV pressed do arrangeCompactBlock #vertical
        on btn_rescaleNow pressed do rescaleCurrentIslands()

        on btn_m90 pressed do rotatePro -90.0
        on btn_m45 pressed do rotatePro -45.0
        on btn_p45 pressed do rotatePro 45.0
        on btn_p90 pressed do rotatePro 90.0
        on btn_180 pressed do rotatePro 180.0

        on btn_ccw pressed do rotatePro spn_angle.value
        on btn_cw pressed do rotatePro (-spn_angle.value)

        on btn_seamAnalyze pressed do seamAnalyze()
        on btn_seamPreview pressed do seamPreview()
        on btn_seamApply pressed do seamApply()
        fn invalidateAtlasAnalysis reasonText =
        (
            seamAnalysisValid = false
            seamSuggestedUVEdges = #{}
            seamTargetFaces = #{}
            atlasChartCount = 0
            atlasWorstEnergy = 0.0
            setStatus reasonText
        )

        on ddl_autoSeamProfile selected idx do invalidateAtlasAnalysis "Profile changed - Generate again."

        on btn_unfold pressed do runNativeUnfold()
        on btn_optimize pressed do runUnfold3D optimizeOnly:true
        on btn_straightenUV pressed do runStraightenUV()
        on btn_straightenShell pressed do runStraightenShell()

        on btn_help pressed do
        (
            messageBox (
                "Rotate UV - Pro\n\n" +
                "CONTROL                     FUNCTION\n" +
                "Auto - Compact Fit           Best compact orientation per target shell\n" +
                "Manual - Selected Edge       Selected edge controls alignment\n" +
                "Capture Islands              Stores current shell scope for repeated rotation\n" +
                "Align H / V icons            Orient target shells horizontally / vertically\n" +
                "Row H / Col V                Simple row or column arrangement\n" +
                "Block H / Block V            Compact landscape / portrait arrangement\n" +
                "Rescale icon                 Rescale target UV clusters now\n" +
                "Rotate option                Compact-orient before arranging\n" +
                "Rescale option               Normalize cluster scale before arranging\n" +
                "Fill Gaps                    Fit smaller/thinner shells into free spaces\n" +
                "Padding                      UV-space gap between arranged shells\n" +
                "Rotate presets               +/-45, +/-90 and 180 degrees\n" +
                "Custom Angle                 CW / CCW rotation\n" +
                "Generate Auto Seam            Native feature-aware structural seam planning\n" +
                "Auto Seam Preview             Select proposed internal seam edges\n" +
                "Auto Seam Apply               Convert proposal to Peel/Pelt seams\n" +
                "Unfold icon                   Native LSCM solve from explicit seams\n" +
                "Optimize icon                 Gentle Unfold3D Optimize\n" +
                "Straighten UV icon            Rectangularize selected quad-grid UV patches\n" +
                "Straighten Shell icon         Rectangularize complete selected quad-grid shells\n\n" +
                "NATIVE AUTO SEAM V2 - FEATURE-AWARE\n" +
                "Workflow: Generate -> Preview -> Apply -> Native Unfold. Auto Seam remains V2.1 and Native Unfold V2 replaces the custom relaxation solver with libigl LSCM initialization plus SLIM symmetric-Dirichlet optimization; seam generation remains V2.1/2.2-compatible and unchanged for general models. The native seam worker analyzes geometry directly: open boundaries are treated as free, structural/cap transition loops are detected from topology and dihedral flow, and tube/strip regions receive controlled longitudinal openings. It returns only internal geometry-edge pairs; true open mesh boundaries are never proposed as seams. Generate/Preview do not alter the Max model. Minimal Seams uses stronger feature thresholds; Low Distortion accepts more structural cuts.\n\n" +
                "STRAIGHTEN\n" +
                "Straighten UV detects clean rectangular quad-grid topology, finds four logical borders, then rebuilds a straight U/V grid using 3D-proportional spacing while preserving UV area and center. Straighten Shell applies the same solver to complete selected shells. Non-grid topology is skipped unchanged.\n\n" +
                "ROTATION CENTER\n" +
                "Handled automatically: Island Center in Auto, Edge Center in Manual.\n\n" +
                "SELECTION SCOPE\n" +
                "With an active UV selection, only touched shells are processed.\n" +
                "With no active UV selection, Auto/Arrange process all UV shells.\n\n" +
                "Category: TEST\n" +
                "Action name: Rotate UV\n" +
                "Created by akg_ai"
            ) title:"Rotate UV - Pro Help"
        )

        on rol_RotateUV open do
        (
            lbl_credit.text = "Created by akg_ai"
            lbl_credit.textAlign = (dotNetClass "System.Drawing.ContentAlignment").MiddleRight
            lbl_credit.foreColor = (dotNetClass "System.Drawing.Color").FromArgb 145 145 145
            lbl_credit.backColor = (dotNetClass "System.Drawing.Color").FromArgb 68 68 68
            lbl_credit.font = dotNetObject "System.Drawing.Font" "Segoe UI" 7.0
            setStatus "Ready - Native FEATURE-AWARE AUTO SEAM available."
        )
    )

    -- Keep the tool above Edit UVWs when the UV editor is already open.
    -- If the editor is not open yet, fall back to the main 3ds Max window.
    local uvEditorHWND = RotateUV_FindUVEditorHWND()
    local toolParentHWND = if uvEditorHWND != undefined then uvEditorHWND else windows.getMAXHWND()

    try
    (
        createDialog rol_RotateUV 304 401 \
            style:#(#style_titlebar, #style_sysmenu, #style_toolwindow) \
            parent:toolParentHWND lockWidth:true lockHeight:true
    )
    catch
    (
        createDialog rol_RotateUV 304 401 \
            style:#(#style_titlebar, #style_sysmenu, #style_toolwindow) \
            parent:(windows.getMAXHWND()) lockWidth:true lockHeight:true
    )
)

macroScript RotateUV
category:"TEST"
tooltip:"Rotate UV"
buttonText:"Rotate UV"
autoUndoEnabled:false
(
    RotateUV_Open()
)

-- DEVELOPMENT AUTO-OPEN: Evaluate All opens the tool directly.
try
(
    RotateUV_Open()
)
catch
(
    messageBox ("Rotate UV auto-open failed.\n\n" + getCurrentException()) title:"Rotate UV - Auto Open Error"
)
