Class Logger {

    # See: https://itinsights.org/PowerShell-async-logging/

    static [string]$DateFormat = "yyyy-MM-dd_HH-mm-ss"

    [String]$CreationDate
    [String]$Hash
    [String]$Node
    [String]$Root
    [String]$FileName
    [String]$ModuleName
    [String]$ModuleVersion
    [String]$ModuleRoot
    [String]$ModuleFileName
    [String]$TaskSummary

    [String]$TextFileRoot
    [String]$TextFileName
    [String]$CsvFileRoot
    [String]$CsvFileName

    [System.Collections.Concurrent.ConcurrentQueue[string]]$TextQueue
    [System.Collections.Concurrent.ConcurrentQueue[string]]$CsvQueue
    [System.Management.Automation.Runspaces.Runspace] $TextRunspace
    [System.Management.Automation.Runspaces.Runspace] $CsvRunspace
    [Powershell]$TextShell
    [Powershell]$CsvShell

    Logger([string]$TaskSummary) {
        $this.Init($TaskSummary, 'C:\TEMP')
    }

    Logger([string]$TaskSummary, [string]$OutputPath) {
        $this.Init($TaskSummary, $OutputPath)
    }

    hidden Init([string]$TaskSummary, [string]$OutputPath) {

        $this.CreationDate = Get-Date -Format $([Logger]::DateFormat)

        $HashData   = $env:COMPUTERNAME + $PSScriptRoot + $this.CreationDate
        $HashStream = [IO.MemoryStream]::new([byte[]][char[]]$HashData)
        $this.Hash  = (Get-FileHash -InputStream $HashStream -Algorithm SHA1).Hash.SubString(0,6)

        $this.Node     = $env:COMPUTERNAME
        $this.Root     = if($MyInvocation.PSCommandPath) {Split-Path $MyInvocation.PSCommandPath}
        $this.FileName = if($MyInvocation.PSCommandPath) {Split-Path $MyInvocation.PSCommandPath -Leaf}

        $Module = (Get-Module | Where-Object {'New-Logger' -in $_.ExportedCommands.Values.Name})

        $this.ModuleName     = $Module.Name
        $this.ModuleVersion  = $Module.Version
        $this.ModuleRoot     = $Module.Path | Split-Path
        $this.ModuleFileName = $Module.Path | Split-Path -Leaf

        $this.TaskSummary = $TaskSummary

        $this.TextFileRoot = $OutputPath
        $this.CsvFileRoot  = $OutputPath

        $this.TextFileName = "$($this.CreateName()).txt"
        $this.CsvFileName  = "$($this.CreateName()).csv"

        $this.TextQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $this.CsvQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        $this.StartLogging()

        $this.CreateTextFile($this.TextFileRoot,$this.TextFileName)
        $this.CreateCsvFile($this.CsvFileRoot, $this.CsvFileName)
    }

    StartLogging() {
        #region Text
            $this.TextRunspace = [RunspaceFactory]::CreateRunspace()
            $this.TextShell    = [Powershell]::Create()

            $this.TextRunspace.ThreadOptions = 'ReuseThread'
            $this.TextShell.runspace = $this.TextRunspace

            $this.TextRunspace.Open()
            $this.TextRunspace.SessionStateProxy.SetVariable('LogQueue', $this.TextQueue)
            $this.TextRunspace.SessionStateProxy.SetVariable('File', (Join-Path $this.TextFileRoot $this.TextFileName))
        #endregion
        #region Csv
            $this.CsvRunspace = [RunspaceFactory]::CreateRunspace()
            $this.CsvShell    = [Powershell]::Create()

            $this.CsvRunspace.ThreadOptions = 'ReuseThread'
            $this.CsvShell.runspace = $this.CsvRunspace

            $this.CsvRunspace.Open()
            $this.CsvRunspace.SessionStateProxy.SetVariable('LogQueue', $this.CsvQueue)
            $this.CsvRunspace.SessionStateProxy.SetVariable('File', (Join-Path $this.CsvFileRoot $this.CsvFileName))
        #endregion

        $AsyncScript = {
            function log
            {
                if(-not $LogQueue.IsEmpty)
                {
                    $StreamWriter = [System.IO.StreamWriter]::new($File, $true) # An appending streamwriter
        
                    while (-not $LogQueue.IsEmpty)
                    {
                        $Line = ''
                        $LogQueue.TryDequeue([ref]$Line) | Out-Null
                        $StreamWriter.WriteLine($Line)
                    }
                    $StreamWriter.Close()
                }
            }

            function Start-Logging
            {
                $LogTimer = New-Object Timers.Timer
                $LogTimer.Interval = 1000
                $LogTimer.Enabled = $True
    
                Register-ObjectEvent -InputObject $LogTimer -EventName 'Elapsed' -Sourceidentifier 'TestTimer' -Action ${function:log} | Out-Null
                #$LogTimer.Start()
            }

            Start-Logging

            Sleep 1
        }

        [void]$this.TextShell.AddScript($AsyncScript.ToString())
        [void]$this.CsvShell.AddScript($AsyncScript.ToString())

        $this.TextShell.BeginInvoke() | Out-Null
        $this.CsvShell.BeginInvoke() | Out-Null
    }

    hidden AddMessageToTextQueue($Message) {
        $AddResult = $false
        while (-not $AddResult) {
            $AddResult = $this.TextQueue.TryAdd($Message)
        }
    }

    hidden AddMessageToCsvQueue($Message) {
        $AddResult = $false
        while (-not $AddResult) {
            $AddResult = $this.CsvQueue.TryAdd($Message)
        }
    }

    hidden CreateFile($Path, $Name) {
        try {
            New-Item -ItemType Directory -Force -Path $Path | Out-Null
            New-Item -ItemType File      -Force -Path $Path -Name $Name | Out-Null
        }
        catch {
            throw
        }
    }

    hidden CreateTextFile($Path, $Name) {
        $this.CreateFile($Path,$Name)
        $this.AddMessageToTextQueue($this.CreateTextHeader())
    }

    hidden CreateCsvFile($Path, $Name) {
        $this.CreateFile($Path,$Name)
        $this.AddMessageToCsvQueue($this.CreateCsvHeader())
    }

    Log([string]$Level, [string]$Message, [string]$Data, [bool]$Console) {
        
        $TextMessage = $this.CreateTextUpdate($Level,$Message,$Data)
        $CsvMessage = $this.CreateCsvUpdate($Level,$Message,$Data)

        $this.AddMessageToTextQueue($TextMessage)
        $this.AddMessageToCsvQueue($CsvMessage)

        if($Console) {
            Write-Host $TextMessage
        }
    }

    hidden [string] CreateTextHeader() {
        $Header = @"
#=========================================================#
  START     :  $($this.CreationDate)
  HASH      :  $($this.Hash)
  NODE      :  $($this.Node)

  OPERATION :  $($this.TaskSummary)
  ROOT      :  $($this.Root)
  FILE      :  $($this.FileName)

  MODULE    :  $($this.ModuleName)
  VERSION   :  $($this.ModuleVersion)
  ROOT      :  $($this.ModuleRoot)
  FILE      :  $($this.ModuleFileName)
#=========================================================#
"@
        return $Header
    }

    hidden [string] CreateTextUpdate([string]$Level, [string]$Message, [string]$Data) {
        if($Data.Length -gt 0) {
            $Line = "[$(Get-Date -Format $([Logger]::DateFormat))] [$($Level)] `"$($Message)`" : $Data "
        } else {
            $Line = "[$(Get-Date -Format $([Logger]::DateFormat))] [$($Level)] `"$($Message)`" "
        }
        return $Line
    }

    hidden [string] CreateCsvHeader() {
        $Row = [PSCustomObject]@{
            timestamp      = $this.CreationDate
            level          = 'INFO'
            message        = 'START'
            data           = ''
            hash           = $this.Hash
            node           = $this.Node
            'task-summary' = $this.TaskSummary
            root           = $this.Root
            filename       = $this.FileName
            'te-version'   = $this.ModuleVersion
            'te-root'      = $this.ModuleRoot
            'te-file'      = $this.ModuleFileName
        }

        $CSV = (ConvertTo-Csv $Row -NoTypeInformation)

        return "$($CSV[0])`r`n$($CSV[1])"
    }

    hidden [PSCustomobject] CreateCsvUpdate([string]$Level, [string]$Message, [string]$Data) {
        $Row = [PSCustomObject]@{
            timestamp      = Get-Date -Format $([Logger]::DateFormat)
            level          = $Level
            message        = $Message
            data           = $Data
            hash           = ''
            node           = ''
            'task-summary' = ''
            root           = ''
            filename       = ''
            'te-version'   = ''
            'te-root'      = ''
            'te-file'      = ''
        }

        $CSV = (ConvertTo-Csv $Row -NoTypeInformation)

        return $CSV[1]
    }

    hidden [string] CreateName() {
        $Name =  "$($this.TaskSummary)_$($this.CreationDate)_$($this.Hash)_LOG"

        return $Name
    }

    StopLogging() {
        while( -not $this.TextQueue.IsEmpty -OR -not $this.CsvQueue.IsEmpty) {
            Start-Sleep -Seconds 1
        }

        Start-Sleep -Milliseconds 250

        $this.TextShell.Dispose()
        $this.TextRunspace.Dispose()
        $this.CsvShell.Dispose()
        $this.CsvRunspace.Dispose()
    }
}

function New-Logger {
    <#
        .SYNOPSIS
            Creates an asynchronous logger.

        .DESCRIPTION
            Creates an asynchronous logger.
            The logger will create text and csv log files in the specified target path, or C:\TEMP by default.
            The logger works asynchronously in the background, so scripts creating logs will not be held up by file I/O.

        .PARAMETER TaskSummary
            A summary of the task being logged.
            This is used to name log files, so it should be short.

        .INPUTS
            None. You cannot pipe objects to this cmdlet.

        .OUTPUTS
            Logger
            This function returns an asynchronous logging object.

        .EXAMPLE
            PS> New-Logger 'Example'
            [Returns a logger with the task summary 'Example']
            [This logger will save logs in the C:\TEMP folder.]
        
        .EXAMPLE
            PS> New-Logger 'Example' 'C:\LOGS\Example_Logs'
            [Returns a logger with the task summary 'Example']
            [This logger will save logs in the C:\LOGS\Example_Logs folder.]

        .EXAMPLE
            PS> New-Logger -TaskSummary 'Example' -Path 'C:\LOGS\Example_Logs'
            [Returns a logger with the task summary 'Example']
            [This logger will save logs in the C:\LOGS\Example_Logs folder.]
    #>
    Param(
        [Parameter(Mandatory=$true, Position=0)]
        $TaskSummary,

        [Parameter(Mandatory=$false, Position=1)]
        $Path
    )

    if($Path) {
        [Logger]::New($TaskSummary,$Path)
    } else {
        [Logger]::New($TaskSummary)
    }
}

function Out-Logger {
    <#
        .SYNOPSIS
            Logs a message with an asynchronous logger.

        .DESCRIPTION
            Logs a message with an asynchronous logger.
            Optional parameters allow setting a severity level and attaching data to the log entry along with the message.
            The text version of the log entry can optionally be sent to the console.

        .PARAMETER Message
            The message to log. This parameter accepts input from the pipeline.

        .PARAMETER Logger
            The logger to log the message with.

        .PARAMETER Level
            The severity level of the message.
            Default value is 'INFO'.

        .PARAMETER Data
            Data to attach to the the log entry.

        .INPUTS
            System.String
            You can pipe strings to this function. When a string is piped, it is applied to the Message parameter.

        .OUTPUTS
            None. This function does not generate any output.

        .EXAMPLE
            PS> Out-Logger $Logger 'Example'
            [Logs the INFO-level message 'Example'.]

        .EXAMPLE
            PS> 'Example' | Out-Logger $Logger
            [Logs the INFO-level message 'Example'.]
        
        .EXAMPLE
            PS> Out-Logger $Logger 'Example' -Console
            [Logs the INFO-level message 'Example', and sends it to the console.]

        .EXAMPLE
            PS> Out-Logger $Logger 'Example' FATAL
            [Logs the FATAL-level message 'Example'.]

        .EXAMPLE
            PS> Out-Logger $Logger 'Example' -Data '123' -Console
            [Logs the INFO-level message 'Example' with attached data '123', and sends it to the console.]
    #>
    [CmdletBinding(DefaultParameterSetName = 'Pipeline')]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName='Pipeline', ValueFromPipeline)]
        [Parameter(Mandatory=$true, ParameterSetName='Standard', Position=1)]
        [String] $Message,

        [Parameter(Mandatory=$true, Position=0)]
        [Logger] $Logger,

        [Parameter(Mandatory=$false, ParameterSetName='Pipeline', Position=1)]
        [Parameter(Mandatory=$false, ParameterSetName='Standard', Position=2)]
        [ValidateSet('TRACE','DEBUG','INFO','WARN','ERROR','FATAL')]
        [String] $Level = 'INFO',

        [Parameter(Mandatory=$false, ParameterSetName='Pipeline', Position=2)]
        [Parameter(Mandatory=$false, ParameterSetName='Standard', Position=3)]
        [String] $Data = '',

        [Parameter(Mandatory=$false)]
        [switch] $Console=$false
    )

    $Logger.Log($Level,$Message,$Data,$Console)
}

function Stop-Logger {
    <#
        .SYNOPSIS
            Stops the asynchronous activities of the logger.

        .DESCRIPTION
            Stops the asynchronous activities of the logger.

        .PARAMETER Logger
            The logger object to stop.

        .INPUTS
            None. You cannot pipe objects to this cmdlet.

        .OUTPUTS
            None.

        .EXAMPLE
            PS> Stop-Logger $Logger
            [Stops the asynchronous activities of the logger.]
            [May take multiple seconds.]
    #>
    Param(
        [Parameter(Mandatory=$true, Position=0)]
        [Logger] $Logger
    )

    $Logger.StopLogging()
}

Export-ModuleMember -Function `
    New-Logger,
    Out-Logger,
    Stop-Logger