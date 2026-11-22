const fs=require("fs"),ganache=require("ganache"),{ethers}=require("ethers");
const b=JSON.parse(fs.readFileSync("build.json"));
const assert=(c,m)=>{if(!c)throw new Error("FAIL "+m);console.log("ok -",m)};
const errName=e=>{try{return new ethers.Interface(b.abi).parseError(e.data)?.name}catch{return null}};
(async()=>{
 const g=ganache.provider({logging:{quiet:true},chain:{hardfork:"shanghai"},wallet:{totalAccounts:4,defaultBalance:1000}});
 const p=new ethers.BrowserProvider(g);
 const [o,a]=await Promise.all([0,1].map(i=>p.getSigner(i)));
 const t=await (await new ethers.ContractFactory(b.abi,b.bytecode,o).deploy()).waitForDeployment();
 const bal=async x=>BigInt(await g.request({method:"eth_getBalance",params:[x,"latest"]}));
 const A=await a.getAddress(), T=await t.getAddress();
 const s1=await t.stakeWeiFor(100);
 try{await t.connect(a).playComputer.staticCall(100,ethers.ZeroAddress,"",{value:s1});assert(false,"x")}catch(e){assert(errName(e)==="HouseTooSmall","needs house bank")}
 await (await t.fundHouse({value:ethers.parseEther("0.05")})).wait();
 let ci=await t.computerInfo(); assert(ci.bankWei===ethers.parseEther("0.05")&&ci.maxStakeCentsVsComputer===15000n,"house bank funded ($150 at $3000)");
 const fee=await t.moveFeeWei(); const GL={gasLimit:800000};
 const cell=(bd,i)=>(Number(bd)>>(i*2))&3;
 const lines=[[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]];
 const pick=bd=>{ for(const L of lines){const v=L.map(i=>cell(bd,i)); if(v.filter(x=>x===1).length===2&&v.includes(0)) return L[v.indexOf(0)];} for(const i of [4,0,2,6,8,1,3,5,7]) if(!cell(bd,i)) return i; };
 const res={3:0,4:0,5:0}; let maxGas=0n, maxOpen=0n;
 for(let k=0;k<12;k++){
   if(k===6) await (await t.setComputer(true,100)).wait(); // computer never blocks
   const bank0=await t.houseBank(), pb0=await bal(A);
   let gasSpent=0n;
   const rc0=await (await t.connect(a).playComputer(100,ethers.ZeroAddress,"",{value:s1,...GL})).wait(); if(rc0.gasUsed>maxOpen)maxOpen=rc0.gasUsed; gasSpent+=rc0.gasUsed*rc0.gasPrice;
   const id=await t.gameCount();
   let G=await t.getGame(id);
   assert(G.vsComputer && G.status===2n && G.turn===1n,`game ${id}: vs computer, player's turn (computer opened: ${G.moves===1n})`);
   while(G.status===2n){ const c0=pick(G.board); try{ await t.connect(a).move.staticCall(id,c0,{value:fee}); }catch(e){ console.log("DEBUG revert",errName(e),e.shortMessage, "cell",c0,"board",G.board.toString(),"moves",G.moves.toString(), e.data); throw e; } const rc=await (await t.connect(a).move(id,pick(G.board),{value:fee,...GL})).wait(); gasSpent+=rc.gasUsed*rc.gasPrice+fee; if(rc.gasUsed>maxGas)maxGas=rc.gasUsed; G=await t.getGame(id); }
   const st=Number(G.status); res[st]++;
   const bank1=await t.houseBank(), pb1=await bal(A);
   const playerDelta=pb1-pb0+gasSpent;
   if(st===3){ assert(playerDelta===s1 && bank1===bank0-s1,"  player won: +stake, house -stake"); }
   else if(st===4){ assert(playerDelta===-s1 && bank1===bank0+s1,"  computer won: player -stake, house +stake"); }
   else { assert(playerDelta===0n && bank1===bank0,"  draw: nothing changes"); }
 }
 console.log("results  X(player) wins:",res[3]," computer wins:",res[4]," draws:",res[5], " max gas/move:",maxGas.toString()," max gas playComputer:",maxOpen.toString());
 assert((await t.escrowWei())===0n,"escrow clean");
 // timeout vs computer
 await (await t.connect(a).playComputer(10,ethers.ZeroAddress,"",{value:await t.stakeWeiFor(10),...GL})).wait();
 const id=await t.gameCount(); let G=await t.getGame(id); const m0=G.moves;
 await g.request({method:"evm_increaseTime",params:[25]}); await g.request({method:"evm_mine",params:[]});
 await (await t.forceMove(id,GL)).wait(); G=await t.getGame(id);
 assert(G.status!==2n || (G.moves===m0+2n && G.turn===1n),"forced player move + instant computer reply");
 // withdraw house
 const ob=await bal(await o.getAddress()); const hb=await t.houseBank();
 const rc=await (await t.withdrawHouse(hb)).wait();
 assert((await t.houseBank())===0n && (await bal(await o.getAddress()))-ob+rc.gasUsed*rc.gasPrice===hb,"owner withdraws house bank");
 assert(await bal(T) >= (await t.escrowWei()),"contract holds escrow");
 // leaderboard + nick
 await (await t.connect(a).setNick("Ania")).wait();
 try{ await t.connect(a).setNick.staticCall("x".repeat(21)); assert(false,"long") }catch(e){ assert(errName(e)==="BadNick","nick max 20 bytes") }
 const rows=await t.getLeaderboard(0,50); const me=rows.find(r=>r.player===A);
 const S=me.s; const xp=S.wins*30n+S.draws*15n+S.losses*5n;
 assert((await t.playersCount())===1n && me.nick==="Ania" && me.points===S.wins*3n+S.draws,"leaderboard row with nick + points ("+S.wins+"W "+S.draws+"D "+S.losses+"L = "+me.points+" pts)");
 assert(S.games===S.wins+S.draws+S.losses && S.xp===xp,"games count "+S.games+" + xp "+S.xp);
 let L=1n; while(BigInt(xp)>=25n*(L+1n)*L) L++; assert(S.level===L,"level "+S.level+" matches xp thresholds; best streak "+S.bestStreak+", cpu wins "+S.cpuWins+", joined "+S.joined);
 await (await t.fundHouse({value:ethers.parseEther("0.01")})).wait();
 await (await t.connect(a).playComputer(10,ethers.ZeroAddress,"Ania2",{value:await t.stakeWeiFor(10),...GL})).wait();
 assert((await t.nickOf(A))==="Ania2" && (await t.playersCount())===1n,"nick updated with game tx, no duplicate player");
 console.log("ALL PASSED");
})().catch(e=>{console.error(e);process.exit(1)});
