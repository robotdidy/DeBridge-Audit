// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "../src/CallProxy_bd3d/contracts/periphery/CallProxy.sol";

contract StateMixingToken {
    mapping(address => uint256) internal balances;
    mapping(address => mapping(address => uint256)) internal allowances;
    uint256 public totalSupply;

    function mint(address account, uint256 amount) external {
        balances[account] += amount;
        totalSupply += amount;
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

contract StateMixingGate {
    CallProxy internal proxy;
    StateMixingToken internal token;
    uint256 internal constant VICTIM_AMOUNT = 100 ether;

    constructor(CallProxy _proxy, StateMixingToken _token) {
        proxy = _proxy;
        token = _token;
        token.mint(address(this), VICTIM_AMOUNT);
    }

    function runVictimAutoClaim() external {
        require(token.transfer(address(proxy), VICTIM_AMOUNT));
        proxy.callERC20(address(token), address(0xBEEF), address(0), "", 0, "", 1);
    }

    function runVictimDirectToProxy() external {
        require(token.transfer(address(proxy), VICTIM_AMOUNT));
    }

    function triggerOuter(address receiver, address reserve) external {
        proxy.callERC20(address(token), reserve, receiver, "", 0, "", 1);
    }
}

contract ReentrantReceiver {
    StateMixingGate internal immutable gate;
    bool internal immutable directToProxy;

    constructor(StateMixingGate _gate, bool _directToProxy) {
        gate = _gate;
        directToProxy = _directToProxy;
    }

    fallback() external {
        bytes4 selector = directToProxy
            ? StateMixingGate.runVictimDirectToProxy.selector
            : StateMixingGate.runVictimAutoClaim.selector;
        (bool ignored, ) = address(gate).call(
            abi.encodeWithSelector(selector)
        );
        ignored;
    }
}

contract CallProxyStateMixingTest {
    function testNestedAutoClaimRollsBackBeforeOuterSweep() external {
        CallProxy proxy = new CallProxy();
        proxy.initialize();

        StateMixingToken token = new StateMixingToken();
        StateMixingGate gate = new StateMixingGate(proxy, token);
        proxy.grantRole(proxy.DEBRIDGE_GATE_ROLE(), address(gate));

        ReentrantReceiver receiver = new ReentrantReceiver(gate, false);
        gate.triggerOuter(address(receiver), address(this));

        require(token.balanceOf(address(proxy)) == 0, "proxy retained nested value");
        require(token.balanceOf(address(this)) == 0, "outer fallback received value");
        require(token.balanceOf(address(gate)) == 100 ether, "nested transfer did not roll back");
    }

    function testDirectTransferToCallProxyCanBeSwept() external {
        CallProxy proxy = new CallProxy();
        proxy.initialize();

        StateMixingToken token = new StateMixingToken();
        StateMixingGate gate = new StateMixingGate(proxy, token);
        proxy.grantRole(proxy.DEBRIDGE_GATE_ROLE(), address(gate));

        ReentrantReceiver receiver = new ReentrantReceiver(gate, true);
        gate.triggerOuter(address(receiver), address(this));

        require(token.balanceOf(address(this)) == 100 ether, "direct CallProxy balance was not swept");
        require(token.balanceOf(address(proxy)) == 0, "proxy retained direct value");
    }
}
