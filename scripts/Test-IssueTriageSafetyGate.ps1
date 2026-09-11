#Requires -Version 7.4
<#
.SYNOPSIS
    Executes the canonical/compiled inline triage gate with sealed fixtures and mocked GitHub transport.
.DESCRIPTION
    Requires Node, Bash, jq, timeout and the gh-aw v0.85.4 setup JS directory.
    Runs the actual preparation, renderer, seal, selected verifier, gate, and native
    label/close handlers. All API writes are mocks; no network is used by tests.
#>
[CmdletBinding()]
param(
    [string] $WorkflowPath = (Join-Path $PSScriptRoot '..\terraform\canary-ring-0\.github\workflows\issue-triage.md'),
    [string] $RuntimeDirectory = $(if ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'gh-aw/actions' } else { '/opt/gh-aw/actions' }),
    [string] $BashPath = $(if ($IsWindows) { 'C:\Program Files\Git\bin\bash.exe' } else { '/bin/bash' }),
    [string[]] $CaseName = @('*')
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-StepBody {
    param([string] $Name, [string] $Key)
    $lines = [IO.File]::ReadAllLines((Resolve-Path $WorkflowPath))
    $found = @(0..($lines.Length - 1) | Where-Object { $lines[$_].Trim() -in @("name: $Name", "- name: $Name") })
    if ($found.Count -ne 1) { throw "Expected one step named '$Name'." }
    $i = $found[0] + 1
    while ($i -lt $lines.Length -and $lines[$i] -notmatch "^\s+$Key`: \|[-+]?$") { $i++ }
    if ($i -eq $lines.Length) { throw "Missing $Key body in '$Name'." }
    $indent = $lines[$i].Length - $lines[$i].TrimStart().Length + 2
    $body = [Collections.Generic.List[string]]::new()
    for ($j = $i + 1; $j -lt $lines.Length; $j++) {
        if ($lines[$j].Trim().Length -eq 0) { $body.Add(''); continue }
        if (-not $lines[$j].StartsWith(' ' * $indent)) { break }
        $body.Add($lines[$j].Substring($indent))
    }
    return ($body -join "`n") + "`n"
}
function Get-StepDefinition {
    param([string] $Name)
    $lines = [IO.File]::ReadAllLines((Resolve-Path $WorkflowPath))
    $found = @(0..($lines.Length - 1) | Where-Object { $lines[$_].Trim() -in @("name: $Name", "- name: $Name") })
    if ($found.Count -ne 1) { throw "Expected one step named '$Name'." }
    $nameIndex = $found[0]
    $indent = $lines[$nameIndex].Length - $lines[$nameIndex].TrimStart().Length
    if (-not $lines[$nameIndex].TrimStart().StartsWith('- ')) { $indent -= 2 }
    $start = $nameIndex
    while ($start -gt 0 -and $lines[$start] -notmatch "^ {$indent}- ") { $start-- }
    $end = $start + 1
    while ($end -lt $lines.Length) {
        if ($lines[$end].Trim().Length -gt 0 -and
            ($lines[$end].Length - $lines[$end].TrimStart().Length) -le $indent) { break }
        $end++
    }
    return ($lines[$start..($end - 1)] -join "`n") + "`n"
}
foreach ($name in @('issue_intents.cjs', 'safe_output_validator.cjs', 'close_issue.cjs', 'add_labels.cjs', 'add_comment.cjs', 'update_pull_request.cjs', 'load_agent_output.cjs')) {
    if (-not (Test-Path (Join-Path $RuntimeDirectory $name))) {
        throw "Missing pinned gh-aw v0.85.4 runtime file '$name'. Supply -RuntimeDirectory pointing to the setup action's JS directory."
    }
}
$source = [IO.File]::ReadAllText((Resolve-Path $WorkflowPath))
$gate = Get-StepBody 'Enforce triage release gate' 'script'
$prepare = Get-StepBody 'Prepare release proof verifier' 'run'
$render = Get-StepBody 'Render triage evidence blocks' 'run'
$seal = Get-StepBody 'Seal triage evidence' 'script'
# Assertions run before fixture selection, so even tiny selectors check wiring.
# A compiler-generated env block can accidentally replace a collector's token
# when its shell embeds a GitHub expression. Inspect the actual emitted step,
# not merely a GH_TOKEN occurrence elsewhere in the workflow.
$credentialSteps = @(
    'Fetch label definitions',
    'Fetch current issue type',
    'Fetch issue close and reopen history',
    'Prefetch PR candidate evidence for target issue',
    'Prefetch duplicate issue candidates for target issue',
    'Fetch release status',
    'Enforce triage release gate'
)
foreach ($name in $credentialSteps) {
    $definition = Get-StepDefinition $name
    $environment = [regex]::Match($definition, '(?m)^( +)env:\s*$')
    if (-not $environment.Success) { throw "Missing credential environment in '$name'." }
    $valueIndent = $environment.Groups[1].Length + 2
    if ($definition -notmatch ("(?m)^ {$valueIndent}GH_TOKEN: " + [regex]::Escape('${{ secrets.GITHUB_TOKEN }}') + '\s*$')) {
        throw "Missing GH_TOKEN binding in '$name'. Every gh collector and selected verifier needs its own trusted token."
    }
}
foreach ($required in @(
    'needs.triage_evidence.outputs.artifact_id', 'needs.triage_evidence.outputs.manifest_sha256',
    'needs.triage_evidence.outputs.producer_attempt',
    'steps.setup-agent-output-env.outputs.GH_AW_AGENT_OUTPUT', 'triage-release-proof.sh',
    'Prepare private triage gate directory', 'Download trusted triage evidence independently',
    'Upload triage gate authorization report', 'triage_evidence:', 'safe_outputs:',
    'TRIAGE_WORKFLOW_SHA', 'TRIAGE_ARTIFACT_ID', 'TRIAGE_MANIFEST_SHA256'
)) {
    if (-not $source.Contains($required)) { throw "Missing gate wiring: $required" }
}
$producerJob = [regex]::Match($source, '(?ms)^  triage_evidence:\r?\n(?<body>.*?)(?=^  [A-Za-z_][A-Za-z0-9_-]*:|\z)')
if (-not $producerJob.Success -or
    -not $producerJob.Groups['body'].Value.Contains('producer_attempt: ${{ steps.seal-triage-evidence.outputs.producer_attempt }}') -or
    -not (Get-StepDefinition 'Enforce triage release gate').Contains('TRIAGE_PRODUCER_ATTEMPT: ${{ needs.triage_evidence.outputs.producer_attempt }}') -or
    -not $seal.Contains("core.setOutput('producer_attempt', producerAttempt)")) {
    throw 'Producer-attempt output or trusted consumer binding is missing.'
}
if (-not $prepare.Contains("<<'TRIAGE_RELEASE_VERIFIER'") -or
    -not $gate.Contains("execFileSync('/bin/bash', [path.join(evidenceDirectory, 'triage-release-proof.sh'), 'selected'") -or
    -not $gate.Contains("fs.renameSync(temporary, outputPath)")) { throw 'Shared verifier or in-place enforcement wiring changed.' }
$gatePosition = $source.IndexOf('name: Enforce triage release gate')
$gateEnd = $source.IndexOf('name: Upload triage gate authorization report', $gatePosition)
if ($source.Substring($gatePosition, $gateEnd - $gatePosition) -match 'continue-on-error:\s*true') { throw 'Gate must not continue after an unexpected crash.' }
if ($WorkflowPath -like '*.lock.yml') {
    if ($source -notmatch 'gh-aw v0\.85\.4|gh-aw.*v0\.85\.4|@v0\.85\.4') { throw 'Expected pinned compiler/runtime v0.85.4.' }
    if (-not $source.Contains('github/gh-aw-actions/setup@2709137ea6c5b0e19aa621454dc643ea8dc526b1')) { throw 'Pinned setup action changed.' }
    if ($gatePosition -ge $source.IndexOf('name: Process Safe Outputs')) { throw 'Gate must precede native dispatch.' }
    foreach ($job in @('agent', 'safe_outputs')) {
        $match = [regex]::Match($source, "(?ms)^  $job`:\r?\n(?<body>.*?)(?=^  [A-Za-z_][A-Za-z0-9_-]*:|\z)")
        if (-not $match.Success -or $match.Groups['body'].Value -notmatch '(?s)needs:.*?triage_evidence') { throw "$job must depend on triage_evidence." }
        if ($job -eq 'safe_outputs' -and ($match.Groups['body'].Value -notmatch 'runs-on: ubuntu-latest' -or $match.Groups['body'].Value -notmatch 'contents: read')) { throw 'Output job needs Ubuntu and contents:read.' }
        if ($job -eq 'safe_outputs') {
            $configuration = [regex]::Match($match.Groups['body'].Value, '(?m)^\s+GH_AW_SAFE_OUTPUTS_HANDLER_CONFIG: (.+)$')
            if (-not $configuration.Success) { throw 'Missing native handler configuration.' }
            $native = $configuration.Groups[1].Value.Trim() | ConvertFrom-Json | ConvertFrom-Json -AsHashtable
            foreach ($key in @('update_issue', 'close_pull_request', 'merge_pull_request', 'dispatch_workflow')) {
                if ($native.ContainsKey($key)) { throw "Alternate write route enabled: $key" }
            }
            if ($native.close_issue.ContainsKey('state_reason') -or
                ($native.close_issue.allowed_state_reason -join ',') -ne 'duplicate,completed' -or
                $native.close_issue.max -ne 1 -or $native.add_comment.max -ne 1 -or $native.add_labels.max -ne 10 -or
                $native.add_labels.issue_intent -ne $false) { throw 'Native limits, REST labels, or generated closure capability changed.' }
        }
    }
    if ($source -notmatch '(?s)"fixing_pr"\s*:\s*\{[^}]*"type"\s*:\s*"integer"' -or
        $source -notmatch '(?s)"version"\s*:\s*\{[^}]*"type"\s*:\s*"integer"') { throw 'Compiled decision integer schema missing.' }
} else {
    $frontmatter = ($source -split '(?m)^---\s*$', 3)[1]
    if ($frontmatter -match '(?m)^  (update-issue|scripts|jobs):') { throw 'Ungated output route enabled.' }
    if ($frontmatter -notmatch '(?s)fixing_pr:\s+type: integer\s+minimum: 0') { throw 'Invalid decision schema.' }
}
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('avm-gate-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
try {
    $input = @{
        gate = $gate; prepare = $prepare; render = $render; seal = $seal
        runtime = (Resolve-Path $RuntimeDirectory).Path; bash = $BashPath; windows = $IsWindows
        patterns = $CaseName
    }
    [IO.File]::WriteAllText((Join-Path $temporaryRoot 'input.json'), ($input | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $runner = @'
const fs = require('fs'), path = require('path'), crypto = require('crypto'), cp = require('child_process'), assert = require('assert/strict');
const input = JSON.parse(fs.readFileSync(path.join(__dirname, 'input.json'), 'utf8'));
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const core = { info(){}, debug(){}, warning(){}, error(){}, setOutput(){}, setFailed(message){throw Error(message);}, startGroup(){}, endGroup(){} };
global.core = core;
const nativeRequire = name => require(path.join(input.runtime, name));
const { normalizeIssueIntentLabelInputs } = nativeRequire('issue_intents.cjs');
const { validateLabels } = nativeRequire('safe_output_validator.cjs');
const effective = label => validateLabels(normalizeIssueIntentLabelInputs([label]).map(l => typeof l === 'string' ? l : l.name), undefined, 10).value?.[0];
const fixed = 'Status: Fixed :white_check_mark:', awaiting = 'Status: Awaiting Release To Be Cut :scissors:', feature = 'Type: Feature Request :heavy_plus_sign:';
const bashPath = p => input.windows ? '/' + p[0].toLowerCase() + p.slice(2).replaceAll('\\', '/') : p;
const write = (p, v) => fs.writeFileSync(p, typeof v === 'string' ? v : JSON.stringify(v));
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const merge = 'c'.repeat(40), main = 'd'.repeat(40), tag = 'b'.repeat(40);
const compare = (head, status = 'ahead') => ({ base_commit:{sha:merge}, merge_base_commit:{sha: status === 'behind' ? head : merge}, status, ahead_by: status === 'behind' ? 0 : 5, behind_by: status === 'behind' ? 5 : 0 });
const cases = [];
function test(name, mutate = () => {}, expected = 'blocked') { cases.push({name, mutate, expected}); }
function candidate(n, required = true) {
  return { number:n,title:'fixture',url:`https://github.com/owner/module/pull/${n}`,state:'MERGED',draft:false,merged:true,body_excerpt:'Fixes #288',
    sources:required ? ['issue_number_search_body','merged_pr_inventory'] : ['merged_pr_inventory'],file_names:['main.tf'],file_names_truncated:false,
    open_inventory:false,merged_inventory:true,lexical_relevance:{score:20,plausible:true,signals:{}} };
}
function fixture() {
  const rows = [candidate(227)];
  const shared = {loaded:true,complete:true,success:true,errors:[],candidate_count:1,open_inventory_count:0,merged_inventory_count:1,required_inspection_count:1,required_inspection_numbers:[227]};
  return {
    decision:{version:1,fixing_pr:56,fix_confidence:'confirmed',release_action:'evaluate_fix',human_reopen_override:false,screening_complete:true,
      fully_inspected_prs:[56,227],screened_inventory_prs:[227],findings:'PR #56 changes the reported assignment. PR #227 is unrelated.',audit:'PR #56 diff and tests; PR #227 diff.'},
    status:{...shared,index_version:1,screening_index_path:'fixture',exact_required_inspection_count:1,exact_required_inspection_numbers:[227],timeline_required_inspection_count:0,timeline_required_inspection_numbers:[],commit_required_inspection_count:0,commit_required_inspection_numbers:[]},
    index:{...shared,version:1,required_inspection:rows,open_inventory_screening:[]},
    history:{loaded:true,events:[]}, initial:{version:1,loaded:true,has_release:true,prs:[{number:227,status:'released',release_tag:'v1.0.0'}]},
    responses:{
      'api --paginate repos/owner/module/releases?per_page=100': [{id:1,tag_name:'v1.0.0',published_at:'2026-09-01T00:00:00Z',draft:false,prerelease:false}],
      'api repos/owner/module/commits/refs%2Fheads%2Fmain': {sha:main},
      'api repos/owner/module/commits/refs%2Ftags%2Fv1.0.0': {sha:tag},
      'api repos/owner/module/pulls/56':{number:56,merged:true,draft:false,merge_commit_sha:merge,base:{ref:'main',repo:{full_name:'owner/module'}}},
      [`api repos/owner/module/compare/${merge}...${main}?per_page=1`]:compare(main),
      [`api repos/owner/module/compare/${merge}...${tag}?per_page=1`]:compare(tag)
    },
    items:[], labels:[fixed,awaiting,feature], artifact:'123', manifestChange:()=>{}, afterSeal:()=>{}, proofChange:null,
    expectedCalls:true, keepFeature:true
  };
}
test('typed 56 outside initial index freshly released',()=>{},'released');
test('first closure needs no prior workflow closure',f=>{
  // A focused contract fixture, not a replay of the incompletely inspected
  // historical incident: empty readable history is not a closure veto.
  f.history={loaded:true,events:[]};
  f.decision.human_reopen_override=false;f.decision.screening_complete=true;
  f.decision.fully_inspected_prs=[56,227];f.decision.screened_inventory_prs=[227];
},'released');
test('initial unknown still permits fresh proof',f=>{ f.initial={version:1,loaded:false,has_release:null,prs:[]}; },'released');
test('old raw C56 completed and Fixed blocked',f=>{f.decision=null;f.items.push({type:'close_issue',issue_number:288,state_reason:'completed',body:'Fixed by #56; closed.'},{type:'add_labels',item_number:288,labels:[fixed]});f.expectedCalls=false;});
test('fresh awaiting never borrows released 227',f=>{f.responses[`api repos/owner/module/compare/${merge}...${tag}?per_page=1`]=compare(tag,'behind');},'awaiting');
test('initial positive cannot rescue failed fresh proof',f=>{f.initial.prs.push({number:56,status:'released',release_tag:'v1.0.0'});delete f.responses['api repos/owner/module/pulls/56'];});
for (const key of ['api --paginate repos/owner/module/releases?per_page=100','api repos/owner/module/commits/refs%2Fheads%2Fmain','api repos/owner/module/commits/refs%2Ftags%2Fv1.0.0','api repos/owner/module/pulls/56']) {
  test('failed API '+key,f=>{delete f.responses[key];});
}
for(const [name,mutate] of [
  ['wrong PR identity',p=>p.number=227],['unmerged',p=>p.merged=false],['draft',p=>p.draft=true],
  ['wrong base',p=>p.base.ref='maintenance'],['wrong repository',p=>p.base.repo.full_name='other/repo'],['missing merge',p=>p.merge_commit_sha=null]
]) test(name,f=>mutate(f.responses['api repos/owner/module/pulls/56']));
for (const [name, change] of [
  ['missing fresh file',(p,file)=>fs.rmSync(file)],
  ['malformed fresh JSON',(p,file)=>write(file,'{')],
  ['duplicate proof entries',(p,file)=>{p.prs.push(p.prs[0]);write(file,p);}],
  ['wrong proof identity',(p,file)=>{p.prs[0].number=227;write(file,p);}],
  ['wrong proof version',(p,file)=>{p.version=2;write(file,p);}],
  ['loaded false',(p,file)=>{p.loaded=false;write(file,p);}],
  ['missing release tag',(p,file)=>{delete p.prs[0].release_tag;write(file,p);}]
]) test(name,f=>{f.proofChange=change;});
test('duplicate release tags fail proof',f=>{f.responses['api --paginate repos/owner/module/releases?per_page=100'].push({...f.responses['api --paginate repos/owner/module/releases?per_page=100'][0],id:2});});
test('raw close cannot piggyback typed release',f=>{f.items.push({type:'close_issue',issue_number:288,state_reason:'completed',body:'Unrelated #227'});f.expectedCalls=false;});
for (const label of [fixed, fixed.toUpperCase(), ` <${fixed}> `, {name:fixed}, {name:fixed,confidence:'INVALID'}, {name:awaiting,suggest:'INVALID'}, {name:`\u001b[31m${awaiting}\u001b[0m`,rationale:'x',confidence:'HIGH'}]) {
  test('reserved effective label '+JSON.stringify(label),f=>{f.items.push({type:'add_labels',item_number:288,labels:[label,feature]});f.expectedCalls=false;});
}
test('mixed string object labels retain metadata',f=>{f.items.push({type:'add_labels',item_number:288,labels:[{name:feature,rationale:'feature request',confidence:'HIGH'},'not a label']});},'released');
for (const value of [0,-1,1.5,9007199254740992,'56',null]) test('bad fixing PR '+JSON.stringify(value),f=>{f.decision.fixing_pr=value;f.expectedCalls=false;});
for (const field of ['version','fixing_pr','fix_confidence','release_action','human_reopen_override','screening_complete','fully_inspected_prs','screened_inventory_prs','findings','audit']) {
  test('omitted metadata '+field,f=>{delete f.decision[field];f.expectedCalls=false;});
}
test('multiple metadata comments',f=>{f.secondComment=true;f.expectedCalls=false;});
test('metadata on another output',f=>{f.items.push({type:'set_issue_type',issue_number:288,issue_type:'Feature',data:{}});f.expectedCalls=false;});
test('unsupported schema version',f=>{f.decision.version=2;f.expectedCalls=false;});
test('duplicate inspected numbers',f=>{f.decision.fully_inspected_prs.push(56);f.expectedCalls=false;});
test('wrong comment target',f=>{f.commentTarget=289;f.expectedCalls=false;});
test('comment conflicting native alias',f=>{f.commentAlias=289;f.expectedCalls=false;});
for(const key of ['pr-number','comment_id','commentId','comment-id','reply_to_id','target']) {
  test('comment native routing escape '+key,f=>{f.commentExtra={[key]:key==='target'?'status':289};f.expectedCalls=false;});
}
test('ingestion errors survive',f=>{f.errors=[{message:'malformed output',type:'add_comment'}];f.expectedCalls=false;});
test('no comment generates fallback',f=>{f.omitComment=true;f.expectedCalls=false;});
for(const reason of [undefined,null,'not_planned','COMPLETED','']) test('unsupported close reason '+String(reason),f=>{f.items.push({type:'close_issue',issue_number:288,state_reason:reason});f.expectedCalls=false;});
test('human reopen prevents completion',f=>{f.decision.human_reopen_override=true;f.expectedCalls=false;});
test('history unavailable prevents completion',f=>{f.history.loaded=false;f.expectedCalls=false;});
test('incomplete collection',f=>{f.status.complete=false;f.expectedCalls=false;});
test('incomplete declared screening',f=>{f.decision.screening_complete=false;f.expectedCalls=false;});
test('missing required inspection',f=>{f.decision.fully_inspected_prs=[56];f.expectedCalls=false;});
test('valid candidate marker cannot replace declared inspection',f=>{
  f.decision.fully_inspected_prs=[];f.expectedCalls=false;f.assertValidCandidateMarker=true;
});
test('missing selected inspection',f=>{f.decision.fully_inspected_prs=[227];f.expectedCalls=false;});
test('missing inventory screening',f=>{f.decision.screened_inventory_prs=[];f.expectedCalls=false;});
test('explicit duplicate independent of PR collection',f=>{
  f.decision.release_action='none';f.decision.fixing_pr=0;f.decision.fix_confidence='none';f.status.complete=false;
  f.items.push({type:'close_issue',issue_number:288,state_reason:'duplicate',duplicate_of:12,body:'untrusted original body'});
  f.expectedCalls=false;
},'duplicate');
for(const veto of ['human','history']) test('duplicate veto '+veto,f=>{
  f.decision.release_action='none'; if(veto==='human') f.decision.human_reopen_override=true; else f.history.loaded=false;
  f.items.push({type:'close_issue',issue_number:288,state_reason:'duplicate',duplicate_of:12});f.expectedCalls=false;
});
test('conflicting duplicate and completion',f=>{f.items.push({type:'close_issue',issue_number:288,state_reason:'duplicate',duplicate_of:12});f.expectedCalls=false;});
test('PR append preserved',f=>{f.items.push({type:'update_pull_request',pull_request_number:56,operation:'append',body:'Fixes #288'});},'released');
test('PR append veto with incomplete screening',f=>{f.decision.screening_complete=false;f.items.push({type:'update_pull_request',pull_request_number:56,operation:'append',body:'Fixes #288'});f.expectedCalls=false;});
function nativePrFixture(f,extra={},expectedWrites=1) {
  f.decision.release_action='none';f.expectedCalls=false;f.nativePr=true;f.expectedPrWrites=expectedWrites;
  f.items.push({type:'update_pull_request',pull_request_number:56,operation:'append',body:'Fixes #288',...extra});
}
test('native PR append only preserves approved metadata',f=>nativePrFixture(f,{
  temporary_id:'aw_pr_123',tainted:true,taint:{source:'fixture'},integrity:{level:'low'}
}));
for(const extra of [{state:'closed'},{base:'maintenance'},{update_branch:true},{draft:true},{title:'Retitle'},{unexpected_mutation:true},{state:'closed',base:'maintenance',update_branch:true}]) {
  test('native PR append rejects '+Object.keys(extra).join('+'),f=>nativePrFixture(f,extra,0));
}
test('native PR append rejects mutation without consuming valid append',f=>{
  nativePrFixture(f,{state:'closed',base:'maintenance',update_branch:true},1);
  f.items.push({type:'update_pull_request',pull_request_number:56,operation:'append',body:'Fixes #288'});
});
test('partial retry accepts producer attempt 1 at consumer attempt 2',f=>{f.consumerAttempt='2';},'released');
test('partial retry still requires fresh selected proof',f=>{
  f.consumerAttempt='2';f.initial.prs.push({number:56,status:'released',release_tag:'v1.0.0'});
  delete f.responses['api repos/owner/module/pulls/56'];
});
test('partial retry preserves duplicate and labels',f=>{
  f.consumerAttempt='2';f.decision.release_action='none';f.expectedCalls=false;
  f.items.push({type:'close_issue',issue_number:288,state_reason:'duplicate',duplicate_of:12,body:'Duplicate of #12'});
},'duplicate');
test('partial retry rejects spoofed producer attempt',f=>{
  f.consumerAttempt='2';f.producerOutputOverride='2';f.expectedCalls=false;f.keepFeature=false;
});
test('partial retry rejects wrong run',f=>{
  f.consumerAttempt='2';f.manifestChange=m=>m.run_id='999';f.expectedCalls=false;f.keepFeature=false;
});
test('partial retry rejects consumer earlier than producer',f=>{
  f.producerAttempt='2';f.consumerAttempt='1';f.expectedCalls=false;f.keepFeature=false;
});
for(const attempt of ['','0','-1','1.5','01','9007199254740992']) {
  test('producer attempt rejects invalid '+JSON.stringify(attempt),f=>{
    f.producerOutputOverride=attempt;f.expectedCalls=false;f.keepFeature=false;
  });
  test('partial retry rejects invalid consumer attempt '+JSON.stringify(attempt),f=>{
    f.consumerAttempt=attempt;f.expectedCalls=false;f.keepFeature=false;
  });
}
for(const [name,change] of [
  ['wrong repository',m=>m.repository='other/repo'],['wrong issue',m=>m.issue_number='1'],['wrong run',m=>m.run_id='999'],
  ['wrong attempt',m=>m.run_attempt='2'],['wrong workflow',m=>m.workflow_sha='other'],['arbitrary executable path',m=>m.files['../evil.sh']='a'.repeat(64)]
]) test('provenance '+name,f=>{f.manifestChange=change;f.expectedCalls=false;f.keepFeature=false;});
test('invalid artifact ID',f=>{f.artifact='not-an-id';f.expectedCalls=false;f.keepFeature=false;});
test('manifest hash mismatch',f=>{f.badHash=true;f.expectedCalls=false;f.keepFeature=false;});
test('missing artifact download',f=>{f.afterSeal=d=>fs.rmSync(d,{recursive:true});f.expectedCalls=false;f.keepFeature=false;});
test('helper tamper cannot execute',f=>{f.afterSeal=d=>fs.appendFileSync(path.join(d,'triage-release-proof.sh'),'\necho unsafe\n');f.expectedCalls=false;f.keepFeature=false;});
test('evidence tamper fails closed',f=>{f.afterSeal=d=>write(path.join(d,'pr-evidence-validation.json'),{valid:true,forged:true});f.expectedCalls=false;f.keepFeature=false;});
test('agent copy cannot authorize or supply helper',f=>{delete f.responses['api repos/owner/module/pulls/56'];f.poisonAgent=true;});
test('taint and temporary IDs survive',f=>{f.tainted=true;},'released');
test('unexpected gate crash is fatal',f=>{f.crash=true;},'crash');
for(const mode of ['success','comment failure','close failure','label failure']) {
  test('native handlers '+mode,f=>{f.nativeMode=mode;},'released');
}
test('native duplicate marker and relationship',f=>{
  f.nativeMode='duplicate';f.decision.release_action='none';
  f.items.push({type:'close_issue',issue_number:288,state_reason:'duplicate',duplicate_of:12,body:'Duplicate of #12'});
  f.expectedCalls=false;
},'duplicate');
test('label batch limit reserves generated label',f=>{
  for(let i=0;i<10;i++)f.items.push({type:'add_labels',item_number:288,labels:[feature]});
},'released');
test('wrong raw target cannot be rescued',f=>{f.items.push({type:'add_labels',item_number:289,labels:[feature]});f.expectedCalls=false;});
test('release label in separate empty batch is removed',f=>{f.items.push({type:'add_labels',item_number:288,labels:[awaiting]});f.expectedCalls=false;});

async function checkNative(items, report, mode) {
  const writes=[], outcomes=[];
  let state='open';
  const fail=()=>Object.assign(new Error('fixture API failure'),{status:422});
  global.context={repo:{owner:'owner',repo:'module'},payload:{issue:{number:288},repository:{full_name:'owner/module',owner:{login:'owner'},name:'module'}},eventName:'issues',runId:777,serverUrl:'https://github.com'};
  const issue=n=>({number:n,title:'Fixture issue',node_id:`node-${n}`,labels:[],state,html_url:`https://github.com/owner/module/issues/${n}`});
  global.github={
    rest:{issues:{
      get:async p=>({data:issue(p.issue_number)}),
      listComments:async()=>({data:[]}),
      createComment:async p=>{
        if(mode==='comment failure' && p.body.startsWith('Fixed by PR'))throw fail();
        writes.push({action:'comment',...p});return {data:{id:100+writes.length,html_url:'https://github.com/owner/module/issues/288#issuecomment-1'}};
      },
      update:async p=>{if(mode==='close failure')throw fail();writes.push({action:'close',...p});state=p.state;return {data:issue(p.issue_number)};},
      addLabels:async p=>{if(mode==='label failure')throw fail();writes.push({action:'labels',...p});return {data:p.labels.map(name=>({name}))};}
    }},
    graphql:async(query,args)=>{assert(query.includes('markAsDuplicate'),'Unexpected native GraphQL call');writes.push({action:'duplicate',...args});return {markAsDuplicate:{duplicate:{id:'node-288',number:288}}};},
    paginate:async(method,args)=>{assert.equal(method,global.github.rest.issues.listComments);return [];}
  };
  const handlers={
    add_comment:await nativeRequire('add_comment.cjs').main({max:1,target:'*'}),
    add_labels:await nativeRequire('add_labels.cjs').main({max:10,target:'*',issue_intent:false}),
    close_issue:await nativeRequire('close_issue.cjs').main({max:1,target:'*',allowed_state_reason:['duplicate','completed'],issue_intent:false})
  };
  for(const item of items)if(handlers[item.type])outcomes.push({type:item.type,result:await handlers[item.type](item,{})});
  const closeOutcome=outcomes.find(o=>o.type==='close_issue');
  const closed=writes.filter(w=>w.action==='close');
  if(['comment failure','close failure'].includes(mode)) {
    assert.equal(closeOutcome.result.success,false);assert.equal(closed.length,0);
  } else {
    assert.equal(closeOutcome.result.success,true,JSON.stringify(closeOutcome));
    assert.equal(closed.length,1);
    const closeIndex=writes.indexOf(closed[0]);
    assert(writes.slice(0,closeIndex).some(w=>w.action==='comment'&&/^(Fixed by PR #56|Duplicate of #12)/.test(w.body)));
  }
  if(mode==='label failure')assert(outcomes.filter(o=>o.type==='add_labels').every(o=>o.result.success===false));
  else assert(writes.some(w=>w.action==='labels'&&w.labels.includes(mode==='duplicate'?feature:fixed)));
  if(mode==='duplicate')assert(writes.some(w=>w.action==='duplicate'&&w.canonicalId==='node-12'));
  assert.equal(report.authorization_only,true);
  assert(report.authorized.includes('close_issue:'+(mode==='duplicate'?'duplicate':'completed')));
}

async function checkNativePr(items, expectedWrites) {
  const writes=[],branchWrites=[];
  const originalBody='Existing PR description.';
  let current={number:56,title:'Original title',body:originalBody,state:'open',base:{ref:'main'},draft:false,head:{sha:merge},html_url:'https://github.com/owner/module/pull/56'};
  global.context={repo:{owner:'owner',repo:'module'},payload:{issue:{number:288}},eventName:'issues',runId:777,serverUrl:'https://github.com'};
  global.github={rest:{pulls:{
    get:async()=>({data:current}),
    updateBranch:async p=>{branchWrites.push(p);return {data:{message:'fixture branch update'}};},
    update:async p=>{writes.push(p);current={...current,...p};return {data:current};}
  }}};
  const handler=await nativeRequire('update_pull_request.cjs').main({
    max:1,target:'*',allow_title:false,allow_body:true,default_operation:'append',footer:false,update_branch:false
  });
  const updates=items.filter(i=>i.type==='update_pull_request');
  assert.equal(updates.length,expectedWrites);
  for(const item of updates) {
    const allowed=['type','repo','pull_request_number','operation','body','temporary_id','tainted','taint','integrity'];
    assert(Object.keys(item).every(key=>allowed.includes(key)),'Non-allowlisted field reached native PR handler');
    assert.equal(item.repo,'owner/module');assert.equal(item.pull_request_number,56);
    assert.equal(item.operation,'append');assert.equal(item.body,'Fixes #288');
    const result=await handler(item,{});
    assert.equal(result.success,true,JSON.stringify(result));
  }
  assert.equal(branchWrites.length,0,'Native handler updated the PR branch');
  assert.equal(writes.length,expectedWrites);
  for(const update of writes) {
    assert.deepEqual(Object.keys(update).sort(),['body','owner','pull_number','repo']);
    assert.equal(update.owner,'owner');assert.equal(update.repo,'module');assert.equal(update.pull_number,56);
    assert.equal(update.body.trim(),originalBody+'\n\n---\n\nFixes #288');
  }
  assert.equal(current.state,'open');assert.deepEqual(current.base,{ref:'main'});assert.equal(current.draft,false);assert.equal(current.title,'Original title');
}

const matches = name => input.patterns.some(p=>new RegExp('^'+p.split('*').map(s=>s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')).join('.*')+'$','i').test(name));
const selected = cases.filter(c=>matches(c.name));
assert(selected.length>0,'No gate scenarios matched CaseName');
async function runCase(c,ordinal) {
  const f=fixture();c.mutate(f);
  const root=path.join(__dirname,`case-${ordinal}`), producer=path.join(root,'producer'), gateDir=path.join(root,'gate'), agent=path.join(root,'agent'), bin=path.join(root,'bin');
  for(const dir of [producer,gateDir,agent,bin]) fs.mkdirSync(dir,{recursive:true});
  const env={...process.env,GH_AW_GITHUB_REPOSITORY:'owner/module',DEFAULT_BRANCH:'main',TRIAGE_REPOSITORY:'owner/module',TRIAGE_DEFAULT_BRANCH:'main',TRIAGE_ISSUE:'288',TRIAGE_WORKFLOW_SHA:'f'.repeat(40),GITHUB_RUN_ID:'777',GITHUB_RUN_ATTEMPT:'1',TRIAGE_GATE_DIRECTORY:gateDir,TRIAGE_ARTIFACT_ID:f.artifact,GH_TOKEN:'fixture-token',GITHUB_TOKEN:'fixture-token',FIXTURE_BIN:bashPath(bin),FIXTURE_CALLS:bashPath(path.join(root,'calls.txt'))};
  env.GITHUB_RUN_ATTEMPT=f.producerAttempt||'1';
  env.RUNNER_TEMP=root;env.GITHUB_REPOSITORY='owner/module';env.GH_AW_WORKFLOW_NAME='issue-triage';
  // Only decorative runtime templates are mocked; handlers and sanitizers are
  // loaded unchanged from the pinned setup bundle.
  env.GH_AW_PROMPTS_DIR=path.join(root,'prompts');fs.mkdirSync(env.GH_AW_PROMPTS_DIR);
  write(path.join(env.GH_AW_PROMPTS_DIR,'safe_outputs_disclosure_header.md'),'Fixture runtime disclosure.\n');
  write(path.join(env.GH_AW_PROMPTS_DIR,'workflow_install_note.md'),'Fixture workflow footer.\n');
  write(path.join(producer,'pr-candidate-status.json'),f.status);write(path.join(producer,'pr-candidate-screening-index.json'),f.index);
  write(path.join(producer,'issue-candidate-index.json'),{loaded:true,complete:true,success:true,errors:[],version:1,query_count:0,queries:[],candidate_count:0,candidates:[],open_candidate_count:0,must_compare:[]});
  write(path.join(producer,'issue-number.txt'),'288\n');write(path.join(producer,'issue-type.txt'),'NONE\n');
  write(path.join(producer,'issue-state-history.json'),f.history);write(path.join(producer,'repo-labels.json'),f.labels.map(name=>({name,description:'fixture'})));
  write(path.join(producer,'release-status.json'),f.initial);
  let mock='#!/usr/bin/env bash\nset -euo pipefail\nprintf "%s\\n" "$*" >> "$FIXTURE_CALLS"\ncase "$*" in\n';
  const quote=s=>"'"+s.replaceAll("'","'\\''")+"'";
  for(const [request,response] of Object.entries(f.responses)) mock+=quote(request)+') printf "%s\\n" '+quote(JSON.stringify(response))+'; exit 0;;\n';
  mock+='*) echo "Fixture missing API response" >&2; exit 99;;\nesac\n';
  write(path.join(bin,'gh'),mock);
  fs.chmodSync(path.join(bin,'gh'),0o755);
  if(input.windows) {
    write(path.join(bin,'jq'),'#!/usr/bin/env bash\nexec "$GH_RELEASE_REAL_JQ" --binary "$@"\n');
    fs.chmodSync(path.join(bin,'jq'),0o755);
  }
  const launch=path.join(root,'launch.sh');
  write(launch,'#!/usr/bin/env bash\nset -euo pipefail\nexport GH_RELEASE_REAL_JQ="$(command -v jq)"\nexport PATH="$FIXTURE_BIN:$PATH"\nexec bash "$@"\n');
  const preparation=path.join(root,'prepare.sh');
  write(preparation,(input.prepare+'\n'+input.render).replaceAll('/tmp/gh-aw/agent',bashPath(producer)));
  cp.execFileSync(input.bash,[bashPath(launch),bashPath(preparation)],{env,timeout:120000});
  if(f.assertValidCandidateMarker)assert.equal(JSON.parse(fs.readFileSync(path.join(producer,'pr-evidence-validation.json'))).valid,true);
  const oldEnv={...process.env};Object.assign(process.env,env);
  try {
    let manifestHash,producerAttempt;
    await new AsyncFunction('require','core',input.seal.replace("const directory = '/tmp/gh-aw/agent';",`const directory = ${JSON.stringify(producer)};`))(require,{...core,setOutput:(k,v)=>{
      if(k==='sha256')manifestHash=v;
      if(k==='producer_attempt')producerAttempt=v;
    }});
    assert.equal(producerAttempt,env.GITHUB_RUN_ATTEMPT,'Seal must capture its own attempt');
    const manifestFile=path.join(producer,'triage-evidence-manifest.json');
    const manifest=JSON.parse(fs.readFileSync(manifestFile));f.manifestChange(manifest);write(manifestFile,manifest);
    // Fixture producer captures the real manifest hash after the simulated
    // producer context change. Consumer still must reject wrong run/repo/issue.
    manifestHash=hash(fs.readFileSync(manifestFile));
    fs.cpSync(producer,path.join(gateDir,'evidence'),{recursive:true});fs.cpSync(producer,agent,{recursive:true});
    f.afterSeal(path.join(gateDir,'evidence'));
    if(f.poisonAgent) {
      write(path.join(agent,'triage-release-proof.sh'),'echo NEVER_EXECUTE_AGENT_HELPER; exit 0');
      write(path.join(agent,'release-status.json'),{version:1,loaded:true,has_release:true,prs:[{number:56,status:'released',release_tag:'evil'}]});
    }
    process.env.TRIAGE_MANIFEST_SHA256=f.badHash?'0'.repeat(64):manifestHash;
    process.env.TRIAGE_PRODUCER_ATTEMPT=Object.hasOwn(f,'producerOutputOverride')?f.producerOutputOverride:producerAttempt;
    process.env.GITHUB_RUN_ATTEMPT=f.consumerAttempt??env.GITHUB_RUN_ATTEMPT;
    const comment={type:'add_comment',item_number:f.commentTarget||288,body:'OLD BODY: Closed as completed and applied Fixed.'};
    if(f.decision)comment.data=f.decision;
    if(f.commentAlias)comment.issue_number=f.commentAlias;
    if(f.commentExtra)Object.assign(comment,f.commentExtra);
    if(f.tainted){comment.tainted=true;comment.temporary_id='aw_comment_123';comment.integrity={level:'low',source:'fixture'};}
    const items=[...(f.omitComment?[]:[comment]),{type:'set_issue_type',issue_number:288,issue_type:'Feature'},{type:'add_labels',item_number:288,labels:[feature]},...f.items];
    if(f.secondComment)items.push({...comment});
    const original={items,errors:f.errors||[],temporary_ids:{aw_original_123:{number:288,repo:'owner/module'}},...(f.tainted?{tainted:true}:{})};
    const output=path.join(agent,'safe-outputs.json');write(output,original);process.env.GH_AW_AGENT_OUTPUT=output;
    let executions=0;
    function fixtureRequire(name) {
      if(path.dirname(name)===path.join(root,'gh-aw','actions'))return nativeRequire(path.basename(name));
      if(name==='child_process')return {...cp,execFileSync:(exe,args,options)=>{
        assert.equal(exe,'/bin/bash');assert.equal(args[1],'selected');assert.equal(args[4],'56');
        assert.equal(path.resolve(args[0]),path.join(gateDir,'evidence','triage-release-proof.sh'));executions++;
        if(f.crash)throw new TypeError('Unexpected fixture crash');
        const result=cp.execFileSync(input.bash,[bashPath(launch),...args.map((a,i)=>[0,2,3].includes(i)?bashPath(a):a)],options);
        if(f.proofChange)f.proofChange(JSON.parse(fs.readFileSync(args[3])),args[3]);
        return result;
      }};
      return require(name);
    }
    if(c.expected==='crash') {
      await assert.rejects(()=>new AsyncFunction('require','core',input.gate)(fixtureRequire,core),/Unexpected fixture crash/);
      assert.deepEqual(JSON.parse(fs.readFileSync(output)).items,[],'Unexpected failure must leave no unsafe replay file');
      console.log('PASS '+c.name);return;
    }
    await new AsyncFunction('require','core',input.gate)(fixtureRequire,core);
    const result=JSON.parse(fs.readFileSync(output)),report=JSON.parse(fs.readFileSync(path.join(gateDir,'triage-gate-report.json')));
    const close=result.items.filter(i=>i.type==='close_issue'), releaseLabels=result.items.filter(i=>i.type==='add_labels').flatMap(i=>i.labels.map(effective)).filter(n=>[fixed,awaiting].includes(n));
    assert.equal(result.items[0].type,'add_comment');assert.equal(result.items[0].item_number,288);
    for(const key of ['pr-number','comment_id','commentId','comment-id','reply_to_id','target'])assert.equal(result.items[0][key],undefined);
    assert(!result.items[0].body.includes('OLD BODY'));assert(!/Closed as completed|applied Fixed/.test(result.items[0].body));
    assert.equal(result.items.filter(i=>i.type==='set_issue_type'&&i.issue_type==='Feature').length,1);
    assert.deepEqual(result.errors,original.errors);assert.deepEqual(result.temporary_ids,original.temporary_ids);
    if(f.keepFeature)assert(result.items.some(i=>i.type==='add_labels'&&i.labels.some(l=>effective(l)===feature)));
    assert(!result.items.some(i=>i.type==='add_labels'&&i.labels.length===0));
    assert(result.items.filter(i=>i.type==='add_labels').length<=10);
    if(c.expected==='released') {
      assert.equal(close.length,1);assert.equal(close[0].state_reason,'completed');assert.deepEqual(releaseLabels,[fixed]);
      assert(close[0].body.includes('PR #56'));assert(close[0].body.includes('v1.0.0'));assert(close[0].body.includes('please reopen'));assert(!close[0].body.includes('#227'));
      assert.equal(report.in_initial_index,false);
    } else if(c.expected==='awaiting') {assert.equal(close.length,0);assert.deepEqual(releaseLabels,[awaiting]);}
    else if(c.expected==='duplicate') {assert.equal(close.length,1);assert.equal(close[0].state_reason,'duplicate');assert.equal(close[0].body,'Duplicate of #12');assert.equal(releaseLabels.length,0);assert(result.items[0].body.includes('please reopen it'));}
    else {assert.equal(close.length,0);assert.equal(releaseLabels.length,0);}
    assert.equal(executions,f.expectedCalls?1:0);
    if(f.tainted){assert.equal(result.tainted,true);assert.equal(result.items[0].temporary_id,'aw_comment_123');for(const item of result.items.filter(i=>i.type==='close_issue')){assert.equal(item.tainted,true);assert.deepEqual(item.integrity,comment.integrity);}}
    if(f.nativePr) {
      await checkNativePr(result.items,f.expectedPrWrites);
      if(c.name.includes('rejects')) {
        assert(report.reasons.includes('pr_append_extra_fields'));
        assert(report.blocked.includes('update_pull_request'));
      }
      const submitted=f.items.find(i=>i.type==='update_pull_request'&&i.temporary_id);
      if(submitted) {
        const approvedPr=result.items.find(i=>i.type==='update_pull_request');
        for(const key of ['temporary_id','tainted','taint','integrity'])assert.deepEqual(approvedPr[key],submitted[key]);
      }
    } else if(c.name.includes('PR append')) assert.equal(result.items.filter(i=>i.type==='update_pull_request').length,c.expected==='released'?1:0);
    const calls=fs.existsSync(path.join(root,'calls.txt'))?fs.readFileSync(path.join(root,'calls.txt'),'utf8').trim().split(/\r?\n/):[];
    assert(calls.length<=200);assert(calls.filter(s=>s.includes('/pulls/')).every(s=>s==='api repos/owner/module/pulls/56'));
    // Feed the exact rewritten file into the actual native loader as well.
    assert.deepEqual(nativeRequire('load_agent_output.cjs').loadAgentOutput().items,result.items);
    if(f.nativeMode)await checkNative(result.items,report,f.nativeMode);
    console.log('PASS '+c.name);
  } finally {
    for(const k of Object.keys(process.env))if(!(k in oldEnv))delete process.env[k];Object.assign(process.env,oldEnv);
  }
}
(async()=>{for(let i=0;i<selected.length;i++)await runCase(selected[i],i);console.log(`All ${selected.length} gate scenarios passed.`);})().catch(error=>{console.error(error.stack);process.exitCode=1;});
'@
    $runnerPath = Join-Path $temporaryRoot 'runner.cjs'
    [IO.File]::WriteAllText($runnerPath, $runner.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    & node $runnerPath
    if ($LASTEXITCODE -ne 0) { throw "Gate fixtures failed for $WorkflowPath." }
} finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}
