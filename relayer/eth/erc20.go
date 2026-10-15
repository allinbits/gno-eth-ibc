package eth

import (
	"context"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
)

func bindERC20(c *Client, token common.Address) *bind.BoundContract {
	return bind.NewBoundContract(token, ERC20ABI, c.EC, c.EC, c.EC)
}

// sendTransferMsg is IICS20TransferMsgs.SendTransferMsg.
type sendTransferMsg struct {
	Denom            common.Address
	Amount           *big.Int
	Receiver         string
	SourceClient     string
	DestPort         string
	TimeoutTimestamp uint64
	Memo             string
}

// SendTransfer sends amount of an ERC20 token (an ICS20 voucher, or any token
// to escrow) over sourceClient with ICS20Transfer, approving the transfer
// contract first. The receipt holds the router's SendPacket event.
func (c *Client) SendTransfer(ctx context.Context, token common.Address, amount *big.Int,
	receiver, sourceClient string, timeout uint64, memo string,
) (*types.Receipt, error) {
	if _, err := c.transact(ctx, bindERC20(c, token), "approve", c.Dep.ICS20Transfer, amount); err != nil {
		return nil, err
	}
	return c.transact(ctx, c.Transfer, "sendTransfer", sendTransferMsg{
		Denom: token, Amount: amount, Receiver: receiver, SourceClient: sourceClient,
		DestPort: "transfer", TimeoutTimestamp: timeout, Memo: memo,
	})
}
