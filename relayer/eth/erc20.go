package eth

import (
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
)

func bindERC20(c *Client, token common.Address) *bind.BoundContract {
	return bind.NewBoundContract(token, ERC20ABI, c.EC, c.EC, c.EC)
}
