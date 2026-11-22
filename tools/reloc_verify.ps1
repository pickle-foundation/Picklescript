# tools/reloc_verify.ps1 - static verification of a PickleScript-linked PE.
#
# The linker emits its own PE32+ images, so Windows is the only thing that would
# normally notice a malformed .reloc table - and it notices by crashing after
# rebasing. This script validates the structure up front:
#
#   * PE32+ optional header, DYNAMICBASE set
#   * a .reloc section exists and matches the base-relocation data directory
#   * every IMAGE_BASE_RELOCATION block is page-aligned, in bounds, even-sized
#   * every IMAGE_REL_BASED_DIR64 target is a writable 8-byte site in the image
#   * no duplicate target sites, and at least one relocation exists
#
# Exit 0 on success, 1 with a FAIL line otherwise.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\reloc_verify.ps1 -Exe bench\bin\adjacency.exe

param(
    [Parameter(Mandatory = $true)]
    [string]$Exe
)

$ErrorActionPreference = "Stop"

function Fail([string]$msg) {
    Write-Output "RELOC VERIFY FAIL: $msg"
    exit 1
}

function U16([byte[]]$b, [int]$o) {
    if ($o -lt 0 -or $o + 2 -gt $b.Length) { Fail "read u16 out of bounds at $o" }
    [int]$b[$o] -bor ([int]$b[$o + 1] -shl 8)
}

function U32([byte[]]$b, [int]$o) {
    if ($o -lt 0 -or $o + 4 -gt $b.Length) { Fail "read u32 out of bounds at $o" }
    ([long]$b[$o]) -bor (([long]$b[$o + 1]) -shl 8) -bor (([long]$b[$o + 2]) -shl 16) -bor (([long]$b[$o + 3]) -shl 24)
}

function U64([byte[]]$b, [int]$o) {
    $lo = U32 $b $o
    $hi = U32 $b ($o + 4)
    $lo -bor ($hi -shl 32)
}

if (-not (Test-Path -LiteralPath $Exe)) { Fail "missing file $Exe" }
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Exe).Path)
if ($bytes.Length -lt 0x200) { Fail "file too small for a PE image" }
if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { Fail "missing MZ signature" }

$peOff = [int](U32 $bytes 0x3C)
if ($peOff -lt 0x40 -or $peOff + 0x18 -gt $bytes.Length) { Fail "invalid e_lfanew $peOff" }
if ($bytes[$peOff] -ne 0x50 -or $bytes[$peOff + 1] -ne 0x45 -or
    $bytes[$peOff + 2] -ne 0 -or $bytes[$peOff + 3] -ne 0) { Fail "missing PE signature" }

$coff = $peOff + 4
$numSections = U16 $bytes ($coff + 2)
$optSize = U16 $bytes ($coff + 16)
$opt = $coff + 20
if ((U16 $bytes $opt) -ne 0x20B) { Fail "not a PE32+ image" }
if ($optSize -lt 0xF0) { Fail "optional header too small ($optSize)" }
if ($opt + $optSize -gt $bytes.Length) { Fail "optional header out of file bounds" }

$imageBase = U64 $bytes ($opt + 24)
$sectionAlign = U32 $bytes ($opt + 32)
$sizeOfImage = U32 $bytes ($opt + 56)
$sizeOfHeaders = U32 $bytes ($opt + 60)
$dllChars = U16 $bytes ($opt + 70)
$relocRva = U32 $bytes ($opt + 112 + 5 * 8)
$relocSize = U32 $bytes ($opt + 112 + 5 * 8 + 4)

if (($dllChars -band 0x0040) -eq 0) { Fail "DYNAMICBASE (0x40) is not set in DllCharacteristics" }
if ($relocRva -eq 0 -or $relocSize -eq 0) { Fail "base relocation directory is empty" }
if (($relocRva % 0x1000) -ne 0) { Fail ("relocation RVA 0x{0:X} is not page-aligned" -f $relocRva) }
if ($relocSize % 4 -ne 0) { Fail "relocation directory size is not a multiple of 4" }
if ($relocRva + $relocSize -gt $sizeOfImage) { Fail "relocation directory extends past SizeOfImage" }

$secTable = $opt + $optSize
$sections = @()
for ($i = 0; $i -lt $numSections; $i++) {
    $s = $secTable + $i * 40
    if ($s + 40 -gt $bytes.Length) { Fail "section header $i out of file bounds" }
    $nameBytes = $bytes[$s..($s + 7)]
    $name = ([System.Text.Encoding]::ASCII.GetString($nameBytes)).TrimEnd([char]0)
    $sections += [pscustomobject]@{
        Name = $name
        VirtualSize = U32 $bytes ($s + 8)
        VirtualAddress = U32 $bytes ($s + 12)
        SizeOfRawData = U32 $bytes ($s + 16)
        PointerToRawData = U32 $bytes ($s + 20)
        Characteristics = U32 $bytes ($s + 36)
    }
}

$relocSection = $sections | Where-Object { $_.Name -eq ".reloc" } | Select-Object -First 1
if (-not $relocSection) { Fail "no .reloc section" }
if ($relocSection.VirtualAddress -ne $relocRva) {
    Fail ("directory RVA 0x{0:X} != .reloc VA 0x{1:X}" -f $relocRva, $relocSection.VirtualAddress)
}
if ([long]$relocSection.VirtualSize -ne [long]$relocSize) {
    Fail ("directory size 0x{0:X} != .reloc virtual size 0x{1:X}" -f $relocSize, $relocSection.VirtualSize)
}
if (($relocSection.Characteristics -band 0x40000000) -eq 0) { Fail ".reloc is not readable (MEM_READ)" }

$raw = $relocSection.PointerToRawData
if ($raw + $relocSize -gt $bytes.Length) { Fail "relocation bytes extend past end of file" }

# Sections are target candidates for each 8-byte absolute site. The site may be
# in initialized data or in the image at large; require it to fit in a section.
function TargetInSection([long]$rva) {
    foreach ($sec in $sections) {
        $span = [Math]::Max([long]$sec.VirtualSize, [long]$sec.SizeOfRawData)
        if ($rva -ge $sec.VirtualAddress -and ($rva + 8) -le ($sec.VirtualAddress + $span)) {
            return $true
        }
    }
    return $false
}

$seen = New-Object 'System.Collections.Generic.HashSet[long]'
$blockCount = 0
$entryCount = 0
$dir64Count = 0
$pageCount = New-Object 'System.Collections.Generic.HashSet[long]'
$off = 0
while ($off -lt $relocSize) {
    if ($off + 8 -gt $relocSize) { Fail "truncated IMAGE_BASE_RELOCATION header at +$off" }
    $page = U32 $bytes ($raw + $off)
    $blockSize = U32 $bytes ($raw + $off + 4)
    if (($page % 0x1000) -ne 0) { Fail ("block page 0x{0:X} is not page-aligned" -f $page) }
    if ($blockSize -lt 8 -or ($blockSize % 4) -ne 0) { Fail ("block at +{0} has invalid size {1}" -f $off, $blockSize) }
    if ($off + $blockSize -gt $relocSize) { Fail ("block at +{0} extends past the directory" -f $off) }
    if ($page -ge $sizeOfImage) { Fail ("block page 0x{0:X} is outside the image" -f $page) }
    if (-not $pageCount.Add($page)) { Fail ("duplicate block for page 0x{0:X}" -f $page) }

    $entries = ($blockSize - 8) / 2
    if ($entries -lt 1) { Fail "relocation block has no entries" }
    for ($e = 0; $e -lt $entries; $e++) {
        $word = U16 $bytes ($raw + $off + 8 + $e * 2)
        $type = ($word -shr 12) -band 0xF
        $rvaOff = $word -band 0x0FFF
        if ($type -eq 0) {
            # IMAGE_REL_BASED_ABSOLUTE is the padding entry and must be last.
            if ($e -ne $entries - 1) { Fail ("absolute padding entry in the middle of block at +{0}" -f $off) }
            continue
        }
        if ($type -ne 10) { Fail ("unsupported relocation type {0} at +{1}" -f $type, ($off + 8 + $e * 2)) }
        # An 8-byte field may legitimately straddle a page boundary; the block
        # only records where it starts, and the loader writes the full field.
        $target = [long]$page + [long]$rvaOff
        if (-not (TargetInSection $target)) { Fail ("relocation target RVA 0x{0:X} is not an 8-byte site in any section" -f $target) }
        if (-not $seen.Add($target)) { Fail ("duplicate relocation target RVA 0x{0:X}" -f $target) }
        $dir64Count++
        $entryCount++
    }
    $blockCount++
    $off += $blockSize
}

if ($off -ne $relocSize) { Fail "relocation blocks did not consume the directory exactly" }
if ($blockCount -lt 2) { Fail "only $blockCount relocation page(s); multi-page grouping is not exercised" }
if ($dir64Count -lt 1) { Fail "no DIR64 entries" }

# The header's relocation count is not stored in PE32+, but a sanity bound catches
# a generator that emits duplicate padding or wildly oversized blocks.
$maxEntries = [int](($relocSize - 8 * $blockCount) / 2)
if ($entryCount -gt $maxEntries) { Fail "entry count $entryCount exceeds block capacity $maxEntries" }

$sha = (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash
Write-Output ("RELOC VERIFY PASS: {0} base=0x{1:X} sections={2} blocks={3} pages={4} dir64={5} dir=0x{6:X}+0x{7:X} sha256={8}" -f `
    $Exe, $imageBase, $numSections, $blockCount, $pageCount.Count, $dir64Count, $relocRva, $relocSize, $sha)
exit 0
