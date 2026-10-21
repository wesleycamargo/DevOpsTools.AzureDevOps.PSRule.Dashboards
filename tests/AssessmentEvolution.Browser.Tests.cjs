const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const {mkdtempSync,writeFileSync,readFileSync} = require('node:fs');
const path=require('node:path');
const {tmpdir}=require('node:os');
const {chromium}=require('playwright');
(async()=>{
  const output=mkdtempSync(path.join(tmpdir(),'assessment-evolution-'));
  const checkpoint=(name,Outcome)=>({Outcome,RuleName:`Rule.${name}`,TargetName:`org.p.${name}`,TargetType:'Repo',TargetObject:{id:{organization:'org',project:'p',resourceName:name}},Info:{DisplayName:name,Annotations:{severity:'Severe',category:'Repositories'}}});
  const states=[['Fail','Fail','Pass','Fail','Fail'],['Fail','Fail','Pass','Pass','Fail'],['Pass','Fail','Fail','Fail']];
  const names=['resolved','persistent','new','recurring','missing'];
  writeFileSync(path.join(output,'fixtures.json'),JSON.stringify({runs:states.map(values=>values.map((v,i)=>checkpoint(names[i],v)))}));
  execFileSync('pwsh',['-NoProfile','-Command',`
    $data = Get-Content "$env:ANALYTICS_TEST_OUTPUT/fixtures.json" -Raw | ConvertFrom-Json
    $snapshots = @()
    for ($i = 0; $i -lt 2; $i++) {
      & $env:ANALYTICS_TEST_SCRIPT -Results @($data.runs[$i]) -Organization org -RunId "org/$i" -Timestamp ([datetime]"2026-01-0$($i+1)") -OutputDirectory "$env:ANALYTICS_TEST_OUTPUT/$i" -ModuleVersion 1 -Collection @{Status='Complete'} -Configuration @{baseline='Default';rulesetHash='known'}
      $snapshots += Get-Content "$env:ANALYTICS_TEST_OUTPUT/$i/assessment-snapshot.json" -Raw | ConvertFrom-Json
    }
    @{schemaVersion='1.0';snapshots=$snapshots;limitations=@('Retention applies.')} | ConvertTo-Json -Depth 30 | Set-Content "$env:ANALYTICS_TEST_OUTPUT/history.json"
    & $env:ANALYTICS_TEST_SCRIPT -Results @($data.runs[2]) -Organization org -RunId org/2 -Timestamp ([datetime]'2026-01-03') -OutputDirectory $env:ANALYTICS_TEST_OUTPUT -ModuleVersion 1 -Collection @{Status='Complete'} -Configuration @{baseline='Default';rulesetHash='known'} -HistoryPath "$env:ANALYTICS_TEST_OUTPUT/history.json"
  `],{env:{...process.env,ANALYTICS_TEST_OUTPUT:output,ANALYTICS_TEST_SCRIPT:path.resolve(__dirname,'../src/scripts/Export-PSRulePipelineReport.ps1')}});
  const browser=await chromium.launch({headless:true});
  try{
    const page=await browser.newPage();const errors=[],network=[];
    page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(/^https?:/.test(r.url()))network.push(r.url());});
    await page.goto(`file://${output}/psrule-dashboard.html`);
    await page.getByRole('button',{name:'Evolution',exact:true}).click();
    for(const state of ['new','resolved','persistent','recurring','scope']) await page.getByRole('heading',{name:`${state}: 1`,exact:true}).waitFor();
    assert.equal(await page.locator('svg circle').count(),3);
    await page.getByRole('button',{name:'Explore underlying findings',exact:true}).first().click();
    assert.ok((await page.locator('#view').textContent()).includes('Rule.new'));
    await page.locator('#compare-before').selectOption('0');
    assert.ok((await page.locator('#view').textContent()).includes('Matched applicable checkpoints: 4'));
    await page.locator('#compare-after').selectOption('0');
    assert.ok((await page.locator('#view').textContent()).includes('chronological order'));
    // Partial and large datasets still render with bounded findings pagination.
    const payload=JSON.parse(readFileSync(path.join(output,'assessment-snapshot.json'),'utf8'));
    payload.collection={Status:'Partial',Projects:[{Project:'p',Status:'Unavailable'}]};
    payload.results=Array.from({length:5000},(_,i)=>({...payload.results[i%4],targetName:`resource-${i}`,resourceName:`resource-${i}`,resourceKey:`r-${i}`,fingerprint:`f-${i}`}));
    payload.history={snapshots:[],limitations:[]};
    let html=readFileSync(path.join(output,'psrule-dashboard.html'),'utf8').replace(/(<script id="report-data" type="application\/json">)[\s\S]*?(<\/script>)/,`$1${JSON.stringify(payload)}$2`);
    await page.goto('about:blank');await page.setContent(html);
    assert.ok((await page.locator('#collection').textContent()).includes('Partial'));
    await page.getByRole('button',{name:'Findings Explorer',exact:true}).click();
    assert.equal(await page.locator('#findings tr').count(),50);
    payload.results=[];
    html=html.replace(/(<script id="report-data" type="application\/json">)[\s\S]*?(<\/script>)/,`$1${JSON.stringify(payload)}$2`);
    await page.goto('about:blank');await page.setContent(html);
    assert.equal(await page.locator('#total').textContent(),'0');
    assert.deepEqual(errors,[]);assert.deepEqual(network,[]);
    console.log('Evolution browser tests passed: selected comparisons, lifecycle drill-down, trends, partial, empty and 5,000 checkpoints.');
  }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
