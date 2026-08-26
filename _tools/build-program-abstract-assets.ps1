[CmdletBinding()]
param(
    [ValidateRange(72, 300)]
    [int]$Dpi = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$programPath = Join-Path $projectRoot 'program/index.md'
$mappingPath = Join-Path $projectRoot 'abstract_book/abstract-book-mapping.csv'
$sourcePdfPath = Join-Path $projectRoot 'documents/asiacomb2026-abstract-book-long.pdf'
$outputDirectory = Join-Path $projectRoot 'documents/abstracts'
$outputJsonPath = Join-Path $projectRoot 'assets/program-abstracts.json'

foreach ($requiredPath in @($programPath, $mappingPath, $sourcePdfPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required source file not found: $requiredPath"
    }
}

$pdfInfoCommand = Get-Command pdfinfo -ErrorAction SilentlyContinue
$pdfToCairoCommand = Get-Command pdftocairo -ErrorAction SilentlyContinue
if (-not $pdfInfoCommand) {
    throw 'pdfinfo was not found on PATH. Install Poppler before building the abstract assets.'
}
if (-not $pdfToCairoCommand) {
    throw 'pdftocairo was not found on PATH. Install Poppler before building the abstract assets.'
}

function ConvertFrom-HtmlFragment {
    param([Parameter(Mandatory = $true)][string]$Html)

    $plainText = [regex]::Replace($Html, '(?s)<[^>]+>', ' ')
    $plainText = [Net.WebUtility]::HtmlDecode($plainText)
    return ([regex]::Replace($plainText, '\s+', ' ')).Trim()
}

function ConvertTo-Slug {
    param([Parameter(Mandatory = $true)][string]$Value)

    $decomposed = $Value.Normalize([Text.NormalizationForm]::FormD)
    $slugBuilder = [Text.StringBuilder]::new()
    foreach ($character in $decomposed.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($character) -ne
            [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$slugBuilder.Append($character)
        }
    }

    $slug = $slugBuilder.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
    $slug = [regex]::Replace($slug, '[^a-z0-9]+', '-')
    return $slug.Trim('-')
}

function Get-PlenaryEntries {
    param([Parameter(Mandatory = $true)][string]$ProgramHtml)

    $entries = [Collections.Generic.List[object]]::new()
    $dayHeadings = [regex]::Matches(
        $ProgramHtml,
        '(?m)^##\s+(?<weekday>Monday|Tuesday|Wednesday|Thursday|Friday)\s+\((?<month>\d{1,2})/(?<day>\d{1,2})\)\s*$'
    )

    foreach ($dayHeading in $dayHeadings) {
        $sectionStart = $dayHeading.Index + $dayHeading.Length
        $nextHeading = [regex]::Match($ProgramHtml.Substring($sectionStart), '(?m)^##\s+')
        $sectionLength = if ($nextHeading.Success) { $nextHeading.Index } else { $ProgramHtml.Length - $sectionStart }
        $sectionHtml = $ProgramHtml.Substring($sectionStart, $sectionLength)

        $month = [int]$dayHeading.Groups['month'].Value
        $dayOfMonth = [int]$dayHeading.Groups['day'].Value
        $conferenceDate = [datetime]::new(2026, $month, $dayOfMonth)
        $dayLabel = $conferenceDate.ToString('dddd, MMMM d', [Globalization.CultureInfo]::InvariantCulture)

        foreach ($rowMatch in [regex]::Matches($sectionHtml, '(?is)<tr\b[^>]*>(?<body>.*?)</tr>')) {
            $rowHtml = $rowMatch.Groups['body'].Value
            if ($rowHtml -notmatch '(?is)>\s*Plenary Talk\s*</strong>') {
                continue
            }

            $timeMatch = [regex]::Match(
                $rowHtml,
                '(?is)<th\b[^>]*class\s*=\s*["''][^"'']*\btime-slot\b[^"'']*["''][^>]*>(?<value>.*?)</th>'
            )
            if (-not $timeMatch.Success) {
                throw "Could not read the plenary time in the $dayLabel schedule."
            }

            $speaker = $null
            $title = $null
            $room = $null
            foreach ($metaMatch in [regex]::Matches(
                $rowHtml,
                '(?is)<span\b[^>]*class\s*=\s*["''][^"'']*\bslot-meta\b[^"'']*["''][^>]*>(?<value>.*?)</span>'
            )) {
                $metaHtml = $metaMatch.Groups['value'].Value
                $metaText = ConvertFrom-HtmlFragment -Html $metaHtml
                if (-not $speaker -and $metaHtml -match '(?is)<strong\b') {
                    $speaker = $metaText
                }
                elseif ($metaText -match '^(?i:Title:)\s*(?<value>.+)$') {
                    $title = $Matches['value'].Trim()
                }
                elseif ($metaText -match '^(?i:Location:)\s*(?<value>.+)$') {
                    $room = $Matches['value'].Trim()
                }
            }

            if ([string]::IsNullOrWhiteSpace($speaker) -or [string]::IsNullOrWhiteSpace($title)) {
                throw "Could not read the plenary speaker/title in the $dayLabel schedule."
            }

            $id = 'plenary-' + (ConvertTo-Slug -Value $speaker)
            $entries.Add([pscustomobject][ordered]@{
                id      = $id
                kind    = 'plenary'
                speaker = $speaker
                title   = $title
                day     = $dayLabel
                time    = ConvertFrom-HtmlFragment -Html $timeMatch.Groups['value'].Value
                room    = $room
                image   = "/documents/abstracts/$id.png"
                page    = 0
            })
        }
    }

    return @($entries)
}

$pdfInfoOutput = & $pdfInfoCommand.Source $sourcePdfPath 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "pdfinfo failed for $sourcePdfPath`n$($pdfInfoOutput -join [Environment]::NewLine)"
}
$pageCountMatch = [regex]::Match(($pdfInfoOutput -join "`n"), '(?m)^Pages:\s*(?<count>\d+)\s*$')
if (-not $pageCountMatch.Success) {
    throw "Could not determine the page count of $sourcePdfPath."
}
$pdfPageCount = [int]$pageCountMatch.Groups['count'].Value
if ($pdfPageCount -ne 166) {
    throw "Expected the finalized Program Book to have 166 pages, but found $pdfPageCount."
}

$programHtml = [IO.File]::ReadAllText($programPath, [Text.Encoding]::UTF8)
$plenaryEntries = @(Get-PlenaryEntries -ProgramHtml $programHtml)
if ($plenaryEntries.Count -ne 9) {
    throw "Expected 9 plenary talks in program/index.md, but found $($plenaryEntries.Count)."
}

$plenaryFirstPage = 8
for ($index = 0; $index -lt $plenaryEntries.Count; $index += 1) {
    $plenaryEntries[$index].page = $plenaryFirstPage + $index
}
$lastPlenaryPage = $plenaryFirstPage + $plenaryEntries.Count - 1

$mappingRows = @(Import-Csv -LiteralPath $mappingPath)
if ($mappingRows.Count -ne 145) {
    throw "Expected 145 contributed abstracts in the mapping CSV, but found $($mappingRows.Count)."
}

$contributedEntries = [Collections.Generic.List[object]]::new()
$seenDays = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$currentDay = $null
$dayOrdinal = 0

for ($index = 0; $index -lt $mappingRows.Count; $index += 1) {
    $row = $mappingRows[$index]
    if ([string]::IsNullOrWhiteSpace($row.SubmissionId)) {
        throw "Mapping row $($index + 1) has no submission ID."
    }

    if ($row.Day -ne $currentDay) {
        if ($seenDays.Contains($row.Day)) {
            throw "Contributed day '$($row.Day)' occurs in more than one block in the mapping CSV."
        }
        [void]$seenDays.Add($row.Day)
        $currentDay = $row.Day
        $dayOrdinal += 1
    }

    # The final PDF has one contributed-day divider before each day's abstracts.
    # With one-based row ordinal, Monday's first abstract is 16 + 1 + 1 = page 18.
    $rowOrdinal = $index + 1
    $pdfPage = $lastPlenaryPage + $dayOrdinal + $rowOrdinal
    $id = "contributed-$($row.SubmissionId)"

    $contributedEntries.Add([pscustomobject][ordered]@{
        id      = $id
        kind    = 'contributed'
        speaker = [string]$row.Speaker
        title   = [string]$row.ScheduledTitle
        day     = [string]$row.Day
        time    = [string]$row.Time
        room    = [string]$row.Room
        image   = "/documents/abstracts/$id.png"
        page    = $pdfPage
    })
}

if ($dayOrdinal -ne 5) {
    throw "Expected 5 contributed-day dividers, but the mapping CSV produced $dayOrdinal."
}

$expectedDayRanges = [ordered]@{
    'Monday, August 24'    = @(18, 47, 30)
    'Tuesday, August 25'   = @(49, 82, 34)
    'Wednesday, August 26' = @(84, 101, 18)
    'Thursday, August 27'  = @(103, 137, 35)
    'Friday, August 28'    = @(139, 166, 28)
}
foreach ($dayLabel in $expectedDayRanges.Keys) {
    $dayEntries = @($contributedEntries | Where-Object { $_.day -eq $dayLabel })
    $expectedFirst, $expectedLast, $expectedCount = $expectedDayRanges[$dayLabel]
    if ($dayEntries.Count -ne $expectedCount -or
        $dayEntries[0].page -ne $expectedFirst -or
        $dayEntries[-1].page -ne $expectedLast) {
        throw "Unexpected page range for ${dayLabel}: expected $expectedFirst-$expectedLast ($expectedCount abstracts)."
    }
}

$allEntries = @($plenaryEntries) + @($contributedEntries)
if ($allEntries.Count -ne 154) {
    throw "Expected 154 program abstracts, but assembled $($allEntries.Count)."
}

foreach ($propertyName in @('id', 'image', 'page')) {
    $duplicates = @($allEntries | Group-Object -Property $propertyName | Where-Object { $_.Count -ne 1 })
    if ($duplicates.Count -gt 0) {
        throw "Program abstract entries do not have unique '$propertyName' values: $($duplicates.Name -join ', ')."
    }
}

$expectedPages = @(8..16) + @(
    18..47
    49..82
    84..101
    103..137
    139..166
)
$actualPages = @($allEntries.page | Sort-Object)
if (($actualPages -join ',') -ne ($expectedPages -join ',')) {
    throw 'The selected final PDF pages do not match the expected plenary and contributed page ranges.'
}

# Homepage-only schedule changes belong here when the finalized Program Book and
# its source mapping should remain unchanged. The page field continues to point
# to the talk's existing abstract page in the book.
$webScheduleOverrides = @{
    'contributed-171' = @{
        day  = 'Friday, August 28'
        time = '11:00-11:30'
        room = 'E'
        note = 'This abstract page shows the former schedule. The talk has moved to Friday, 11:00–11:30, Room E.'
    }
}
foreach ($entryId in $webScheduleOverrides.Keys) {
    $entry = @($allEntries | Where-Object { $_.id -eq $entryId })
    if ($entry.Count -ne 1) {
        throw "Expected one abstract entry for homepage override '$entryId', but found $($entry.Count)."
    }

    $override = $webScheduleOverrides[$entryId]
    $entry[0].day = $override.day
    $entry[0].time = $override.time
    $entry[0].room = $override.room
    $entry[0] | Add-Member -NotePropertyName note -NotePropertyValue $override.note
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$tempDirectory = Join-Path $tempBase ('asiacomb-program-abstracts-' + [guid]::NewGuid().ToString('N'))
$tempDirectory = [IO.Path]::GetFullPath($tempDirectory)
if (-not $tempDirectory.StartsWith($tempBase + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use a temporary directory outside the system temporary folder: $tempDirectory"
}

New-Item -ItemType Directory -Path $tempDirectory | Out-Null
try {
    Write-Host "Rendering $pdfPageCount finalized Program Book pages at $Dpi DPI..."
    $temporaryPrefix = Join-Path $tempDirectory 'page'
    & $pdfToCairoCommand.Source -png -r $Dpi $sourcePdfPath $temporaryPrefix
    if ($LASTEXITCODE -ne 0) {
        throw 'pdftocairo failed while rendering the finalized Program Book.'
    }

    $temporaryPages = @(Get-ChildItem -LiteralPath $tempDirectory -File -Filter 'page-*.png')
    if ($temporaryPages.Count -ne $pdfPageCount) {
        throw "Expected pdftocairo to render $pdfPageCount pages, but found $($temporaryPages.Count)."
    }

    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    Get-ChildItem -LiteralPath $outputDirectory -File -Filter '*.png' -ErrorAction SilentlyContinue |
        Remove-Item -Force

    $pageNumberWidth = $pdfPageCount.ToString().Length
    foreach ($entry in $allEntries) {
        $pageNumber = ([int]$entry.page).ToString().PadLeft($pageNumberWidth, '0')
        $renderedPagePath = Join-Path $tempDirectory "page-$pageNumber.png"
        if (-not (Test-Path -LiteralPath $renderedPagePath -PathType Leaf)) {
            throw "Rendered page not found: $renderedPagePath"
        }

        $destinationPath = Join-Path $outputDirectory "$($entry.id).png"
        [IO.File]::Copy($renderedPagePath, $destinationPath, $true)
    }
}
finally {
    if (Test-Path -LiteralPath $tempDirectory -PathType Container) {
        Get-ChildItem -LiteralPath $tempDirectory -Force -File -ErrorAction SilentlyContinue |
            Remove-Item -Force
        Remove-Item -LiteralPath $tempDirectory -Force
    }
}

$outputFiles = @(Get-ChildItem -LiteralPath $outputDirectory -File -Filter '*.png')
if ($outputFiles.Count -ne $allEntries.Count) {
    throw "Expected $($allEntries.Count) generated PNG files, but found $($outputFiles.Count)."
}

$expectedFileNames = @($allEntries | ForEach-Object { "$($_.id).png" } | Sort-Object)
$actualFileNames = @($outputFiles.Name | Sort-Object)
if (($expectedFileNames -join "`n") -ne ($actualFileNames -join "`n")) {
    throw 'Generated PNG filenames do not exactly match the program abstract entries.'
}

foreach ($outputFile in $outputFiles) {
    if ($outputFile.Length -le 8) {
        throw "Generated image is unexpectedly small: $($outputFile.FullName)"
    }
    $signature = [IO.File]::ReadAllBytes($outputFile.FullName)[0..7]
    if (($signature -join ',') -ne '137,80,78,71,13,10,26,10') {
        throw "Generated file is not a valid PNG: $($outputFile.FullName)"
    }
}

$json = ConvertTo-Json -InputObject @($allEntries) -Depth 4
$json = ($json -replace "`r`n", "`n") + "`n"
[IO.File]::WriteAllText($outputJsonPath, $json, [Text.UTF8Encoding]::new($false))

$roundTripEntries = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($outputJsonPath, [Text.Encoding]::UTF8))
$roundTripCount = if ($roundTripEntries -is [array]) { $roundTripEntries.Length } else { 1 }
if ($roundTripCount -ne 154) {
    throw "Generated JSON did not round-trip to 154 entries; found $roundTripCount."
}

$totalBytes = ($outputFiles | Measure-Object -Property Length -Sum).Sum
$averageBytes = [math]::Round($totalBytes / $outputFiles.Count)
Write-Host "Generated $($allEntries.Count) abstract images and $outputJsonPath."
Write-Host ("PNG total: {0:N2} MiB; average: {1:N0} KiB; range: {2:N0}-{3:N0} KiB." -f
    ($totalBytes / 1MB),
    ($averageBytes / 1KB),
    (($outputFiles | Measure-Object -Property Length -Minimum).Minimum / 1KB),
    (($outputFiles | Measure-Object -Property Length -Maximum).Maximum / 1KB))
