import { keccak256, toHex, encodeAbiParameters, concatHex } from 'viem'

const COMMIT_TYPEHASH = keccak256(toHex('Commit(uint256 roundId,uint8 slot,bytes32 commitment,bytes32 modelHash)'))
const REVEAL_TYPEHASH = keccak256(toHex('Reveal(uint256 roundId,uint8 slot,bool verdict,bytes32 reasonHash,bytes32 salt)'))

const roundId = 7n
const slot = 3
const commitment = keccak256(toHex('commitment-fixture'))
const modelHash = keccak256(toHex('model-fixture'))
const reasonHash = keccak256(toHex('reason-fixture'))
const salt = keccak256(toHex('salt-fixture'))

const commitStruct = keccak256(encodeAbiParameters(
  [{type:'bytes32'},{type:'uint256'},{type:'uint8'},{type:'bytes32'},{type:'bytes32'}],
  [COMMIT_TYPEHASH, roundId, slot, commitment, modelHash]))

const revealStruct = keccak256(encodeAbiParameters(
  [{type:'bytes32'},{type:'uint256'},{type:'uint8'},{type:'bool'},{type:'bytes32'},{type:'bytes32'}],
  [REVEAL_TYPEHASH, roundId, slot, true, reasonHash, salt]))

const commitmentFromParts = keccak256(encodeAbiParameters(
  [{type:'bool'},{type:'bytes32'},{type:'bytes32'}], [true, reasonHash, salt]))

console.log(JSON.stringify({
  commitment, modelHash, reasonHash, salt,
  commitStruct, revealStruct, commitmentFromParts,
}, null, 2))
