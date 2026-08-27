// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "../src/CallProxy_bd3d/contracts/periphery/CallProxy.sol";

contract ResidueToken {
    mapping(address => uint256) internal balances;
    mapping(address => mapping(address => uint256)) internal allowances;

    function mint(address account, uint256 amount) external {
        balances[account] += amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "balance");
        balances[msg.sender] -= amount;
        balances[recipient] += amount;
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool) {
        require(balances[owner] >= amount, "balance");
        require(allowances[owner][msg.sender] >= amount, "allowance");
        allowances[owner][msg.sender] -= amount;
        balances[owner] -= amount;
        balances[recipient] += amount;
        return true;
    }
}

contract ResidueSwapReceiver {
    function swap(
        ResidueToken input,
        ResidueToken output,
        address proxy,
        uint256 amount
    ) external {
        require(input.transferFrom(proxy, address(this), amount), "pull input");
        require(output.transfer(proxy, amount), "return output");
    }
}

contract ResidueGate {
    CallProxy internal immutable proxy;

    constructor(CallProxy _proxy) {
        proxy = _proxy;
    }

    function runSwap(
        ResidueToken input,
        address reserve,
        address receiver,
        bytes calldata data
    ) external {
        proxy.callERC20(address(input), reserve, receiver, data, 0, "", 1);
    }

    function runSweep(
        ResidueToken token,
        address reserve,
        bytes calldata data
    ) external {
        proxy.callERC20(address(token), reserve, address(token), data, 0, "", 1);
    }
}

contract CrossTokenCallProxyResidueTest {
    function testForeignOutputIsLeftAndLaterClaimCanDrainIt() external {
        CallProxy proxy = new CallProxy();
        proxy.initialize();

        ResidueGate gate = new ResidueGate(proxy);
        proxy.grantRole(proxy.DEBRIDGE_GATE_ROLE(), address(gate));

        ResidueToken input = new ResidueToken();
        ResidueToken output = new ResidueToken();
        ResidueSwapReceiver receiver = new ResidueSwapReceiver();

        uint256 amount = 100 ether;
        input.mint(address(proxy), amount);
        output.mint(address(receiver), amount);

        gate.runSwap(
            input,
            address(this),
            address(receiver),
            abi.encodeWithSelector(
                ResidueSwapReceiver.swap.selector,
                input,
                output,
                address(proxy),
                amount
            )
        );

        require(input.balanceOf(address(proxy)) == 0, "input was not consumed");
        require(output.balanceOf(address(proxy)) == amount, "foreign output was not stranded");

        // A later claim for `output` approves the token contract itself. Its
        // transferFrom call can therefore move the pre-existing balance.
        gate.runSweep(
            output,
            address(this),
            abi.encodeWithSelector(
                ResidueToken.transferFrom.selector,
                address(proxy),
                address(this),
                amount
            )
        );

        require(output.balanceOf(address(proxy)) == 0, "residue remained");
        require(output.balanceOf(address(this)) == amount, "residue was not drained");
    }
}
