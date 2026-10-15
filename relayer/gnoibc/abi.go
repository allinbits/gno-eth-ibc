// Package gnoibc converts tm2 (gno.land) light client data — signed headers,
// validator sets and ICS23 store proofs — into the ABI-encoded messages that
// the GnoLightClient Solidity contract accepts. A relayer can use it as is.
package gnoibc

import (
	"github.com/ethereum/go-ethereum/accounts/abi"
)

// The Go structs below mirror the Solidity structs in
// contracts/src/msgs/IGnoLightClientMsgs.sol field for field; go-ethereum's
// abi package matches them by (capitalised) name.

type Validator struct {
	PubKey      []byte // 64-byte uncompressed secp256k1 key, X || Y
	VotingPower uint64
}

type HeaderFields struct {
	Height             uint64
	TimeSeconds        uint64
	TimeNanos          uint32
	NextValidatorsHash [32]byte
	AppHash            [32]byte
	// Merkle siblings of the six leaves the contract re-encodes itself:
	// leaf 0, subtree 4..7, subtree 8..9, leaf 12, subtree 14..15.
	VersionLeafHash        [32]byte
	TxsAndLastBlockIDHash  [32]byte
	LastCommitAndDataHash  [32]byte
	ConsensusLeafHash      [32]byte
	ResultsAndProposerHash [32]byte
}

type CommitSig struct {
	ValidatorIndex uint32
	TrustedIndex   uint32
	TimeSeconds    uint64
	TimeNanos      uint32
	R              [32]byte
	S              [32]byte
	V              uint8
}

type Commit struct {
	Round        uint32
	PartSetTotal uint32
	PartSetHash  [32]byte
	Signatures   []CommitSig
}

type Header struct {
	SignedHeader      HeaderFields
	Commit            Commit
	ValidatorSet      []Validator
	TrustedHeight     uint64
	TrustedValidators []Validator
}

type Misbehaviour struct {
	Header1 Header
	Header2 Header
}

type InnerOp struct {
	Prefix []byte
	Suffix []byte
}

type ExistenceProof struct {
	Key        []byte
	Value      []byte
	LeafPrefix []byte
	Path       []InnerOp
}

type NonExistenceProof struct {
	Key   []byte
	Left  ExistenceProof
	Right ExistenceProof
}

type MembershipProof struct {
	StoreProof ExistenceProof
	RootProof  ExistenceProof
}

type NonMembershipProof struct {
	StoreProof NonExistenceProof
	RootProof  ExistenceProof
}

type TrustThreshold struct {
	Numerator   uint64
	Denominator uint64
}

type ClientState struct {
	ChainId        string
	RevisionNumber uint64
	LatestHeight   uint64
	TrustLevel     TrustThreshold
	TrustingPeriod uint64
	MaxClockDrift  uint64
	IsFrozen       bool
}

type ConsensusState struct {
	Timestamp          uint64
	AppHash            [32]byte
	NextValidatorsHash [32]byte
}

func m(name, typ string, comps ...abi.ArgumentMarshaling) abi.ArgumentMarshaling {
	return abi.ArgumentMarshaling{Name: name, Type: typ, Components: comps}
}

var (
	validatorComps = []abi.ArgumentMarshaling{m("pubKey", "bytes"), m("votingPower", "uint64")}
	headerComps    = []abi.ArgumentMarshaling{
		m("signedHeader", "tuple",
			m("height", "uint64"),
			m("timeSeconds", "uint64"),
			m("timeNanos", "uint32"),
			m("nextValidatorsHash", "bytes32"),
			m("appHash", "bytes32"),
			m("versionLeafHash", "bytes32"),
			m("txsAndLastBlockIDHash", "bytes32"),
			m("lastCommitAndDataHash", "bytes32"),
			m("consensusLeafHash", "bytes32"),
			m("resultsAndProposerHash", "bytes32"),
		),
		m("commit", "tuple",
			m("round", "uint32"),
			m("partSetTotal", "uint32"),
			m("partSetHash", "bytes32"),
			m("signatures", "tuple[]",
				m("validatorIndex", "uint32"),
				m("trustedIndex", "uint32"),
				m("timeSeconds", "uint64"),
				m("timeNanos", "uint32"),
				m("r", "bytes32"),
				m("s", "bytes32"),
				m("v", "uint8"),
			),
		),
		m("validatorSet", "tuple[]", validatorComps...),
		m("trustedHeight", "uint64"),
		m("trustedValidators", "tuple[]", validatorComps...),
	}
	existComps = []abi.ArgumentMarshaling{
		m("key", "bytes"), m("value", "bytes"), m("leafPrefix", "bytes"),
		m("path", "tuple[]", m("prefix", "bytes"), m("suffix", "bytes")),
	}
	nonExistComps = []abi.ArgumentMarshaling{
		m("key", "bytes"), m("left", "tuple", existComps...), m("right", "tuple", existComps...),
	}

	headerArgs        = mustArgs(m("header", "tuple", headerComps...))
	misbehaviourArgs  = mustArgs(m("misbehaviour", "tuple", m("header1", "tuple", headerComps...), m("header2", "tuple", headerComps...)))
	membershipArgs    = mustArgs(m("proof", "tuple", m("storeProof", "tuple", existComps...), m("rootProof", "tuple", existComps...)))
	nonMembershipArgs = mustArgs(m("proof", "tuple", m("storeProof", "tuple", nonExistComps...), m("rootProof", "tuple", existComps...)))
	existArgs         = mustArgs(m("proof", "tuple", existComps...))
	nonExistArgs      = mustArgs(m("proof", "tuple", nonExistComps...))
	clientStateArgs   = mustArgs(m("clientState", "tuple",
		m("chainId", "string"), m("revisionNumber", "uint64"), m("latestHeight", "uint64"),
		m("trustLevel", "tuple", m("numerator", "uint64"), m("denominator", "uint64")),
		m("trustingPeriod", "uint64"), m("maxClockDrift", "uint64"), m("isFrozen", "bool")))
	consensusStateArgs = mustArgs(m("consensusState", "tuple",
		m("timestamp", "uint64"), m("appHash", "bytes32"), m("nextValidatorsHash", "bytes32")))
)

func mustArgs(am abi.ArgumentMarshaling) abi.Arguments {
	t, err := abi.NewType(am.Type, "", am.Components)
	if err != nil {
		panic(err)
	}
	return abi.Arguments{{Name: am.Name, Type: t}}
}

// The Pack* helpers produce exactly abi.encode(<struct>) as Solidity's
// abi.decode(bytes, (<Struct>)) expects.

func PackHeader(h Header) ([]byte, error)                   { return headerArgs.Pack(h) }
func PackMisbehaviour(mb Misbehaviour) ([]byte, error)      { return misbehaviourArgs.Pack(mb) }
func PackMembershipProof(p MembershipProof) ([]byte, error) { return membershipArgs.Pack(p) }
func PackNonMembershipProof(p NonMembershipProof) ([]byte, error) {
	return nonMembershipArgs.Pack(p)
}
func PackClientState(cs ClientState) ([]byte, error)            { return clientStateArgs.Pack(cs) }
func PackConsensusState(cs ConsensusState) ([]byte, error)      { return consensusStateArgs.Pack(cs) }
func PackExistenceProof(p ExistenceProof) ([]byte, error)       { return existArgs.Pack(p) }
func PackNonExistenceProof(p NonExistenceProof) ([]byte, error) { return nonExistArgs.Pack(p) }

// UnpackClientState decodes GnoLightClient.getClientState().
func UnpackClientState(bz []byte) (ClientState, error) {
	vals, err := clientStateArgs.Unpack(bz)
	if err != nil {
		return ClientState{}, err
	}
	return *abi.ConvertType(vals[0], new(ClientState)).(*ClientState), nil
}
