package ibc

import (
	"regexp"
	"strconv"
	"strings"
)

// isRevisionFormat matches a chain id of the form `{name}-{revision}`, as
// gno.land's p/aib/ibc/types IsRevisionFormat (ibc-go's rule).
var isRevisionFormat = regexp.MustCompile(`^.*[^\n-]-{1}[1-9][0-9]*$`).MatchString

// ParseChainID returns the revision number a chain id carries: N for
// `{name}-{N}` (gnoland-1 is revision 1), 0 for any other form. It is the
// rule gno.land applies to its own heights (types.ParseChainID in
// p/aib/ibc/types), so a client of a gno chain is created at this revision.
func ParseChainID(chainID string) uint64 {
	if !isRevisionFormat(chainID) {
		return 0
	}
	parts := strings.Split(chainID, "-")
	revision, err := strconv.ParseUint(parts[len(parts)-1], 10, 64)
	if err != nil {
		return 0 // the format admits digits alone: only an overflow fails
	}
	return revision
}
