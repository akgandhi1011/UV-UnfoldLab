/*
    Rotate UV - macro registration only.

    Drop this .mcr in <user macros> and the button appears under
    Customize -> Customize User Interface -> Category "TEST".

    This file deliberately contains NOTHING but the macroScript. The previous
    release shipped a .mcr that was a byte-for-byte copy of the .ms, including a
    development auto-open block, so the tool dialog opened by itself whenever Max
    evaluated the macros folder.

    Requirements:
      - Rotate_UV_PRO_NATIVE_UNFOLD_V2.ms on the script path (or run it once).
      - RotateUV_Unfold.exe and RotateUV_AutoSeam.exe, version 3.0.0 or newer,
        beside the .ms or in <scripts>\RotateUVAtlas\.
*/

macroScript RotateUV
category:"TEST"
tooltip:"Rotate UV"
buttonText:"Rotate UV"
autoUndoEnabled:false
(
    local opener = undefined
    try(opener = RotateUV_Open)catch(opener = undefined)

    if opener == undefined do
    (
        -- The tool has not been evaluated yet this session: find and run the script.
        local candidates = #()
        try(append candidates ((getDir #userScripts) + "\\Rotate_UV_PRO_NATIVE_UNFOLD_V2.ms"))catch()
        try(append candidates ((getDir #scripts) + "\\Rotate_UV_PRO_NATIVE_UNFOLD_V2.ms"))catch()
        try(append candidates ((getDir #userScripts) + "\\RotateUVAtlas\\Rotate_UV_PRO_NATIVE_UNFOLD_V2.ms"))catch()
        try(append candidates ((getDir #scripts) + "\\RotateUVAtlas\\Rotate_UV_PRO_NATIVE_UNFOLD_V2.ms"))catch()

        local loaded = false
        for c in candidates while not loaded do
        (
            if c != undefined and doesFileExist c do
            (
                try(fileIn c; loaded = true)catch(loaded = false)
            )
        )
        try(opener = RotateUV_Open)catch(opener = undefined)

        if opener == undefined do
        (
            messageBox "Rotate_UV_PRO_NATIVE_UNFOLD_V2.ms was not found on the script path.\n\nPut it in your scripts folder, or run it once from Scripting -> Run Script." \
                title:"Rotate UV"
        )
    )

    if opener != undefined do opener()
)
