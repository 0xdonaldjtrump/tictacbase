const fs=require("fs"),ganache=require("ganache"),{ethers}=require("ethers");
const b=JSON.parse(fs.readFileSync("build.json"));
const assert=(c,m)=>{if(!c)throw new Error("FAIL "+m);console.log("ok -",m)};
const expectRevert=async(p,name,m)=>{try{await (await p).wait?.();throw new Error("noerr")}catch(e){if(e.message==="noerr")throw new Error("FAIL (no revert) "+m);const ok=!name||(e.data&&new ethers.Interface(b.abi).parseError(e.data)?.name===name)||(e.message||"").includes(name);if(!ok)console.log("  got:",e.shortMessage||e.message);assert(ok,m)}};
(async()=>{
 const g=ganache.provider({logging:{quiet:true},chain:{hardfork:"shanghai"},wallet:{totalAccounts:6,defaultBalance:1000}});
 const p=new ethers.BrowserProvider(g);
 const [o,a,bb,c]=await Promise.all([0,1,2,3].map(i=>p.getSigner(i)));
 const bal=async x=>BigInt(await g.request({method:"eth_getBalance",params:[typeof x==="string"?x:await x.getAddress(),"latest"]}));
 const F=new ethers.ContractFactory(b.abi,b.bytecode,o);
 const t=await F.deploy(); await t.waitForDeployment(); const T=await t.getAddress();
 const GL={gasLimit:600000};
 // session wallets
 const wa=ethers.Wallet.createRandom().connect(p), wb=ethers.Wallet.createRandom().connect(p); const sa=new ethers.NonceManager(wa), sb=new ethers.NonceManager(wb); sa.address=wa.address; sb.address=wb.address;
 const stake=await t.stakeWeiFor(100); assert(stake===333333333333333n,"stake $1 in wei (fallback price)");
 assert(await t.validStake(10)&&await t.validStake(500)&&!(await t.validStake(5))&&!(await t.validStake(510))&&!(await t.validStake(15)),"stake limits $0.10-$5 step $0.10");
 await expectRevert(t.connect(a).createGame.staticCall(15,sa.address,"",{value:stake}),"BadStake","bad stake rejected");
 const topup=ethers.parseEther("0.01");
 const ob0=await bal(o);
 await (await t.connect(a).createGame(100,sa.address,"",{value:stake+topup})).wait();
 assert(await bal(sa.address)===topup,"extra forwarded to session wallet");
 assert((await t.openGamesCount())===1n,"open game listed");
 await expectRevert(t.connect(a).joinGame.staticCall(1,sa.address,"",{value:stake}),"OwnGame","cannot join own game");
 await expectRevert(t.connect(bb).joinGame.staticCall(1,sb.address,"",{value:stake-1n}),"FeeTooLow","join needs full stake");
 await (await t.connect(bb).joinGame(1,sb.address,"",{value:stake+topup})).wait();
 let G=await t.getGame(1);
 assert(G.status===2n && (G.turn===1n||G.turn===2n) && G.deadline-G.lastMove===20n,"playing, random first turn, first move 20s");
 assert((await t.openGamesCount())===0n,"removed from open list");
 const fee=await t.moveFeeWei();
 const sess={1:sa,2:sb};
 const notTurn=G.turn===1n?sb:sa;
 await expectRevert(t.connect(notTurn).move.staticCall(1,4,{value:fee}),"NotYourTurn","wrong player can't move");
 await expectRevert(t.connect(sess[Number(G.turn)]).move.staticCall(1,4,{value:fee-1n}),"FeeTooLow","move needs fee");
 // play: first player takes 0,1,2 (win) while other takes 3,4
 const first=Number(G.turn), second=3-first;
 const play=async(side,cell)=>{await (await t.connect(sess[side]).move(1,cell,{value:fee,...GL})).wait();};
 const ownerBefore=await bal(o);
 await play(first,0); await play(second,3); await play(first,1); await play(second,4);
 const winnerMain= first===1? await a.getAddress(): await bb.getAddress();
 const wb0=await bal(winnerMain);
 await play(first,2);
 G=await t.getGame(1);
 assert(G.status===BigInt(first===1?3:4) && G.winLine===0n,"winner detected on top row");
 assert((await bal(winnerMain))-wb0===stake*2n,"winner received both stakes to MAIN wallet");
 assert((await bal(o))-ownerBefore===fee*5n,"5 move fees went to owner");
 assert((await t.escrowWei())===0n,"escrow cleared");
 const st=await t.stats(winnerMain); assert(st.wins===1n,"stats updated");
 // ---- timeout game ----
 await (await t.connect(a).createGame(50,sa.address,"",{value:await t.stakeWeiFor(50)})).wait();
 await (await t.connect(bb).joinGame(2,sb.address,"",{value:await t.stakeWeiFor(50)})).wait();
 await expectRevert(t.connect(c).forceMove.staticCall(2),"NotYet","forceMove not before deadline");
 await g.request({method:"evm_increaseTime",params:[21]}); await g.request({method:"evm_mine",params:[]});
 G=await t.getGame(2); const late=Number(G.turn);
 await expectRevert(t.connect(sess[late]).move.staticCall(2,0,{value:fee}),"TooLate","late move rejected");
 await (await t.connect(c).forceMove(2,GL)).wait();
 G=await t.getGame(2);
 assert(G.moves===1n && G.forcedMask!==0n && Number(G.turn)===3-late && G.deadline-G.lastMove===10n,"computer placed random mark, turn passed, 10s timer");
 // let the computer finish the whole game
 for(let i=0;i<8;i++){ G=await t.getGame(2); if(G.status!==2n)break; await g.request({method:"evm_increaseTime",params:[11]}); await g.request({method:"evm_mine",params:[]}); await (await t.connect(c).forceMove(2,GL)).wait(); }
 G=await t.getGame(2); assert(G.status>=3n&&G.status<=5n,"abandoned game always ends (status "+G.status+", moves "+G.moves+")");
 assert((await t.escrowWei())===0n,"escrow cleared after forced game");
 // ---- draw ----
 await (await t.connect(a).createGame(10,sa.address,"",{value:await t.stakeWeiFor(10)})).wait();
 await (await t.connect(bb).joinGame(3,sb.address,"",{value:await t.stakeWeiFor(10)})).wait();
 G=await t.getGame(3); const f=Number(G.turn), s=3-f;
 // draw pattern: f:0,2,3,7,8? use known draw: X0 O1 X2 O4 X3 O5 X7 O6 X8
 const seq=[[f,0],[s,1],[f,2],[s,4],[f,3],[s,5],[f,7],[s,6],[f,8]];
 const ab0=await bal(a), bb0=await bal(bb);
 for(const [side,cell] of seq){ await (await t.connect(sess[side]).move(3,cell,{value:fee,...GL})).wait(); }
 G=await t.getGame(3); assert(G.status===5n,"draw detected");
 const s10=await t.stakeWeiFor(10);
 assert((await bal(a))-ab0===s10 && (await bal(bb))-bb0===s10,"draw refunds both stakes");
 // ---- cancel ----
 const s5=await t.stakeWeiFor(500);
 await (await t.connect(c).createGame(500,ethers.ZeroAddress,"",{value:s5+1000n})).wait();
 await expectRevert(t.connect(a).cancelGame.staticCall(4),"NotCreator","only creator cancels");
 const cb0=await bal(c); const rc=await (await t.connect(c).cancelGame(4)).wait();
 assert((await bal(c))-cb0+rc.gasUsed*rc.gasPrice===s5,"cancel refunds stake");
 assert((await t.openGamesCount())===0n && (await t.escrowWei())===0n,"open list + escrow clean");
 // main wallet can also move (session lost)
 await (await t.connect(a).createGame(20,ethers.ZeroAddress,"",{value:await t.stakeWeiFor(20)})).wait();
 await (await t.connect(bb).joinGame(5,ethers.ZeroAddress,"",{value:await t.stakeWeiFor(20)})).wait();
 G=await t.getGame(5); const mainOf={1:a,2:bb};
 await (await t.connect(mainOf[Number(G.turn)]).move(5,4,{value:fee,...GL})).wait();
 assert((await t.getGame(5)).moves===1n,"main wallet can move without session");
 const [ids,list]=await t.getPlayerGames(await a.getAddress(),10); assert(ids[0]===5n&&ids.length===4,"player history newest first");
 // admin
 await expectRevert(t.connect(a).setMoveFee.staticCall(1),"NotOwner","only owner admin");
 await (await t.setTimeouts(15,5)).wait(); assert((await t.moveTimeout())===15n,"owner sets timeout");
 await (await t.setPaused(true)).wait();
 await expectRevert(t.connect(a).createGame.staticCall(10,ethers.ZeroAddress,"",{value:s5}),"Paused","paused blocks new games");
 // running game 5 can still finish while paused
 G=await t.getGame(5); await (await t.connect(mainOf[Number(G.turn)]).move(5,0,{value:fee,...GL})).wait(); assert((await t.getGame(5)).moves===2n,"running game continues when paused");
 const inf=await t.info(); console.log("info",inf.map(String).join(" "));
 const rcm=await (await t.connect(mainOf[Number((await t.getGame(5)).turn)]).move(5,8,{value:fee,...GL})).wait();
 console.log("gas per move:",rcm.gasUsed.toString());
 console.log("ALL PASSED");
})().catch(e=>{console.error(e);process.exit(1)});
