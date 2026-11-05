' Jarvis - esegue un comando SENZA mostrare nessuna finestra (nemmeno il lampo di powershell/cmd).
' Uso (dall'Utilita' di pianificazione): wscript.exe //B //Nologo lancia-nascosto.vbs "<file con la riga di comando>"
' Il file .cmdline contiene una sola riga: il comando completo. Creato da nascondi-attivita.ps1.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
If WScript.Arguments.Count < 1 Then WScript.Quit 2
If Not fso.FileExists(WScript.Arguments(0)) Then WScript.Quit 3
cmd = Trim(fso.OpenTextFile(WScript.Arguments(0), 1, False, 0).ReadAll)
If Len(cmd) = 0 Then WScript.Quit 4
WScript.Quit sh.Run(cmd, 0, True)
