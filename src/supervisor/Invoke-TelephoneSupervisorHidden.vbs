Option Explicit

Dim args, shell, command, exitCode
Set args = WScript.Arguments
If args.Count <> 2 Then WScript.Quit 2

Set shell = CreateObject("WScript.Shell")
command = QuoteArg(args.Item(0)) & _
    " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & _
    QuoteArg(args.Item(1))
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

Function QuoteArg(value)
    QuoteArg = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
