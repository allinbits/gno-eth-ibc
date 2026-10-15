package ethgno

import (
	"crypto/sha256"
	"math/big"
)

type bigInt = big.Int

// pubkeysTree returns the layers of the SSZ tree of a sync committee's
// pubkeys vector, leaves first; len(pubkeys) is a power of two.
func pubkeysTree(pubkeys [][]byte) [][][]byte {
	layer := make([][]byte, len(pubkeys))
	for i, pk := range pubkeys {
		chunk := make([]byte, 32)
		copy(chunk, pk[32:])
		layer[i] = hash2(pk[:32], chunk)
	}
	layers := [][][]byte{layer}
	for len(layer) > 1 {
		next := make([][]byte, len(layer)/2)
		for i := range next {
			next[i] = hash2(layer[2*i], layer[2*i+1])
		}
		layers = append(layers, next)
		layer = next
	}
	return layers
}

// PubkeysRoot is hash_tree_root(Vector[BLSPubkey, len(pubkeys)]), the
// pubkeys commitment of a sync committee summary.
func PubkeysRoot(pubkeys []string) []byte {
	layers := pubkeysTree(hexes(pubkeys))
	return layers[len(layers)-1][0]
}

func hash2(a, b []byte) []byte {
	h := sha256.Sum256(append(append([]byte{}, a...), b...))
	return h[:]
}
