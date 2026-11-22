const solc=require("solc"),fs=require("fs");
const input={language:"Solidity",sources:{"TicTacBase.sol":{content:fs.readFileSync("TicTacBase.sol","utf8")}},
settings:{optimizer:{enabled:true,runs:200},viaIR:false,evmVersion:"paris",outputSelection:{"*":{"*":["abi","evm.bytecode.object","evm.deployedBytecode.object"]}}}};
const out=JSON.parse(solc.compile(JSON.stringify(input)));
(out.errors||[]).forEach(e=>console.log(e.severity,e.formattedMessage));
const c=out.contracts["TicTacBase.sol"].TicTacBase;
fs.writeFileSync("build.json",JSON.stringify({abi:c.abi,bytecode:"0x"+c.evm.bytecode.object}));
console.log("deployed bytes",c.evm.deployedBytecode.object.length/2, "solc", require("solc").version());
