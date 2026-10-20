param([long]$WindowHandle,[string]$ExpectedTitle,[ValidateSet('ready','status','pause','resume','stop')][string]$Action='status',[string]$Guard,[string]$ExpectedEpoch,[string]$Output)
$ErrorActionPreference='Stop'
$answer='error'
try {
    if ([IO.File]::ReadAllText($Guard) -ne [string]$ExpectedEpoch) { throw 'Stale reader command' }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $element=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)
    if (!$element -or !$element.Current.Name.StartsWith($ExpectedTitle)) { throw 'Reader identity changed' }
    $process=Get-Process -Id $element.Current.ProcessId -ErrorAction Stop
    if ($process.ProcessName -ne 'msedge') { throw 'Reader process changed' }
    if ($Action -eq 'ready') {
        $docCondition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Document)
        $doc=$element.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$docCondition)
        $answer=if ($doc) {'ready'} else {'waiting'}
    } else {
    $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Button)
    $buttons=$element.FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition)
    $pause=$null; $play=$null; $close=$null
    foreach ($button in $buttons) {
        if ($button.Current.Name -match '^(?:Close read aloud|Close Read Aloud|Close Read aloud)') { $close=$button; break }
    }
    if ($close) {
        # Only siblings within the Read Aloud control's toolbar/pane can be
        # playback controls. Never match arbitrary browser/media buttons.
        $scope=[System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($close)
        if ($scope.Current.ControlType -in @([System.Windows.Automation.ControlType]::ToolBar,[System.Windows.Automation.ControlType]::Pane)) {
            foreach ($button in $scope.FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition)) {
                $name=$button.Current.Name
                if ($name -match '^Pause(?:\s|$)') { $pause=$button }
                if ($name -match '^(?:Play|Resume)(?:\s|$)') { $play=$button }
            }
        }
    }
    $target=$null
    switch ($Action) {
        'pause' { $target=$pause }
        'resume' { $target=$play }
        'stop' { $target=$close }
    }
    if ($Action -ne 'status') {
        if (!$target) { throw 'Native Read Aloud control unavailable' }
        if ([IO.File]::ReadAllText($Guard) -ne [string]$ExpectedEpoch) { throw 'Stale reader command' }
        $pattern=$target.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $pattern.Invoke()
        $answer='controlled'
    } elseif ($pause) { $answer='playing' }
    elseif ($play -and $close) { $answer='stopped' }
    else { $answer='waiting' }
    }
} catch { $answer='error' }
[IO.File]::WriteAllText($Output,$answer,(New-Object Text.UTF8Encoding($false)))
