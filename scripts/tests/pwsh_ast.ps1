# The PowerShell parser's view of scripts, for the release workflow guard (test_release.py).
# Usage: pwsh -NoProfile -NonInteractive -File scripts/tests/pwsh_ast.ps1 <in.json> <out.json>
# in.json: a JSON array of script texts. out.json: one object per script: parse errors, the names of
# the functions it defines and their bodies, every command (the function it is in, name as the
# parser resolves it, invocation operator,
# element texts, redirection texts, whether every redirection follows the last element), every
# member access (static or not, a call or not, target, member, text), every assignment (left side,
# text), every variable path.
param([string]$InputPath, [string]$OutputPath)
$ErrorActionPreference = 'Stop'
$scripts = @([IO.File]::ReadAllText($InputPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
$result = foreach ($text in $scripts) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput([string]$text, [ref]$tokens, [ref]$errors)
    $commands = foreach ($c in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $last = ($c.CommandElements | ForEach-Object { $_.Extent.EndOffset } | Measure-Object -Maximum).Maximum
        $outer = $c.Parent
        while ($outer -and -not ($outer -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $outer = $outer.Parent }
        [ordered]@{
            function         = if ($outer) { $outer.Name } else { $null }
            name             = $c.GetCommandName()
            op               = [string]$c.InvocationOperator
            elements         = @($c.CommandElements | ForEach-Object { $_.Extent.Text })
            redirections     = @($c.Redirections | ForEach-Object { $_.Extent.Text })
            redirection_last = -not @($c.Redirections | Where-Object { $_.Extent.StartOffset -lt $last }).Count
        }
    }
    $members = foreach ($m in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)) {
        [ordered]@{
            static = [bool]$m.Static
            invoke = $m -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
            target = $m.Expression.Extent.Text
            member = $m.Member.Extent.Text
            text   = $m.Extent.Text
        }
    }
    $assignments = foreach ($a in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        [ordered]@{ left = $a.Left.Extent.Text; text = $a.Extent.Text }
    }
    $variables = foreach ($v in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $v.VariablePath.UserPath
    }
    $definitions = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    $functions = foreach ($f in $definitions) { $f.Name }
    $bodies = foreach ($f in $definitions) { [ordered]@{ name = $f.Name; text = $f.Body.Extent.Text } }
    [ordered]@{
        errors    = @($errors | ForEach-Object { $_.Message })
        functions = @($functions)
        bodies    = @($bodies)
        commands    = @($commands)
        members     = @($members)
        assignments = @($assignments)
        variables   = @($variables)
    }
}
[IO.File]::WriteAllText($OutputPath, (ConvertTo-Json -Depth 8 -InputObject @($result)), [Text.UTF8Encoding]::new($false))
