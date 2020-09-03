// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

pragma experimental ABIEncoderV2;

library Params {
    struct Pool {
        address[] tokens;
        uint[] balances;
        uint[] weights;
        uint swapFee;
    }
    
    struct CRP {
        uint initialSupply;
        uint minimumWeightChangeBlockPeriod;
        uint addTokenTimeLockInBlocks;
    }
}

library RightsManager {
    struct Rights {
        bool canPauseSwapping;
        bool canChangeSwapFee;
        bool canChangeWeights;
        bool canAddRemoveTokens;
        bool canWhitelistLPs;
        bool canChangeCap;
    }
}

abstract contract ERC20 {
    function approve(address spender, uint amount) external virtual returns (bool);
    function transfer(address dst, uint amt) external virtual returns (bool);
    function transferFrom(address sender, address recipient, uint amount) external virtual returns (bool);
    function balanceOf(address whom) external view virtual returns (uint);
    function allowance(address, address) external view virtual returns (uint);
}

abstract contract BalancerOwnable {
    function setController(address controller) external virtual;
}

abstract contract AbstractPool is ERC20, BalancerOwnable {
    function setSwapFee(uint swapFee) external virtual;
    function setPublicSwap(bool public_) external virtual;
    
    function joinPool(uint poolAmountOut, uint[] calldata maxAmountsIn) external virtual;
    function joinswapExternAmountIn(
        address tokenIn, uint tokenAmountIn, uint minPoolAmountOut
    ) external virtual returns (uint poolAmountOut);
}

abstract contract BPool is AbstractPool {
    function finalize() external virtual;
    function bind(address token, uint balance, uint denorm) external virtual;
    function rebind(address token, uint balance, uint denorm) external virtual;
    function unbind(address token) external virtual;
    function isBound(address t) external view virtual returns (bool);
    function getCurrentTokens() external view virtual returns (address[] memory);
    function getFinalTokens() external view virtual returns(address[] memory);
    function getBalance(address token) external view virtual returns (uint);
}

abstract contract BFactory {
    function newBPool() external virtual returns (BPool);
}

abstract contract ConfigurableRightsPool is AbstractPool {
    struct PoolParams {
        string poolTokenSymbol;
        string poolTokenName;
        address[] constituentTokens;
        uint[] tokenBalances;
        uint[] tokenWeights;
        uint swapFee;
    }

    function createPool(
        uint initialSupply, uint minimumWeightChangeBlockPeriod, uint addTokenTimeLockInBlocks
    ) external virtual;
    function createPool(uint initialSupply) external virtual;
    function setCap(uint newCap) external virtual;
    function updateWeight(address token, uint newWeight) external virtual;
    function updateWeightsGradually(uint[] calldata newWeights, uint startBlock, uint endBlock) external virtual;
    function commitAddToken(address token, uint balance, uint denormalizedWeight) external virtual;
    function applyAddToken() external virtual;
    function removeToken(address token) external virtual;
    function whitelistLiquidityProvider(address provider) external virtual;
    function removeWhitelistedLiquidityProvider(address provider) external virtual;
    function bPool() external view virtual returns (BPool);
}

abstract contract CRPFactory {
    function newCrp(
        address factoryAddress,
        ConfigurableRightsPool.PoolParams calldata params,
        RightsManager.Rights calldata rights
    ) external virtual returns (ConfigurableRightsPool);
}

/********************************** WARNING **********************************/
//                                                                           //
// This contract is only meant to be used in conjunction with ds-proxy.      //
// Calling this contract directly will lead to loss of funds.                //
//                                                                           //
/********************************** WARNING **********************************/

contract BActions {

    // --- Pool Creation ---

    function create(
        BFactory factory,
        Params.Pool calldata params,
        bool finalize
    ) external returns (BPool pool) {
        require(params.tokens.length == params.balances.length, "ERR_LENGTH_MISMATCH");
        require(params.tokens.length == params.weights.length, "ERR_LENGTH_MISMATCH");

        pool = factory.newBPool();
        pool.setSwapFee(params.swapFee);

        for (uint i = 0; i < params.tokens.length; i++) {
            ERC20 token = ERC20(params.tokens[i]);
            require(token.transferFrom(msg.sender, address(this), params.balances[i]), "ERR_TRANSFER_FAILED");
            _safeApprove(token, address(pool), params.balances[i]);
            pool.bind(params.tokens[i], params.balances[i], params.weights[i]);
        }

        if (finalize) {
            pool.finalize();
            require(pool.transfer(msg.sender, pool.balanceOf(address(this))), "ERR_TRANSFER_FAILED");
        } else {
            pool.setPublicSwap(true);
        }
    }
    
    function createSmartPool(
        CRPFactory factory,
        BFactory bFactory,
        string calldata symbol,
        string calldata name,
        Params.Pool calldata poolParams,
        Params.CRP calldata crpParams,
        RightsManager.Rights calldata rights
    ) external returns (ConfigurableRightsPool crp) {
        require(poolParams.tokens.length == poolParams.balances.length, "ERR_LENGTH_MISMATCH");
        require(poolParams.tokens.length == poolParams.weights.length, "ERR_LENGTH_MISMATCH");

        ConfigurableRightsPool.PoolParams memory params = ConfigurableRightsPool.PoolParams({
            poolTokenSymbol: symbol,
            poolTokenName: name,
            constituentTokens: poolParams.tokens,
            tokenBalances: poolParams.balances,
            tokenWeights: poolParams.weights,
            swapFee: poolParams.swapFee
        });

        crp = factory.newCrp(
            address(bFactory),
            params,
            rights
        );
        
        for (uint i = 0; i < poolParams.tokens.length; i++) {
            ERC20 token = ERC20(poolParams.tokens[i]);
            require(token.transferFrom(msg.sender, address(this), poolParams.balances[i]), "ERR_TRANSFER_FAILED");
            _safeApprove(token, address(crp), poolParams.balances[i]);
        }
        
        crp.createPool(
            crpParams.initialSupply,
            crpParams.minimumWeightChangeBlockPeriod,
            crpParams.addTokenTimeLockInBlocks
        );
        require(crp.transfer(msg.sender, crpParams.initialSupply), "ERR_TRANSFER_FAILED");
        // DSProxy instance keeps pool ownership to enable management
    }
    
    // --- Joins ---
    
    function joinPool(
        BPool pool,
        uint poolAmountOut,
        uint[] calldata maxAmountsIn
    ) external {
        address[] memory tokens = pool.getFinalTokens();
        _join(pool, tokens, poolAmountOut, maxAmountsIn);
    }
    
    function joinSmartPool(
        ConfigurableRightsPool pool,
        uint poolAmountOut,
        uint[] calldata maxAmountsIn
    ) external {
        address[] memory tokens = pool.bPool().getCurrentTokens();
        _join(pool, tokens, poolAmountOut, maxAmountsIn);
    }

    function joinswapExternAmountIn(
        AbstractPool pool,
        ERC20 token,
        uint tokenAmountIn,
        uint minPoolAmountOut
    ) external {
        require(token.transferFrom(msg.sender, address(this), tokenAmountIn), "ERR_TRANSFER_FAILED");
        _safeApprove(token, address(pool), tokenAmountIn);
        uint poolAmountOut = pool.joinswapExternAmountIn(address(token), tokenAmountIn, minPoolAmountOut);
        require(pool.transfer(msg.sender, poolAmountOut), "ERR_TRANSFER_FAILED");
    }
    
    // --- Pool management (common) ---
    
    function setPublicSwap(AbstractPool pool, bool publicSwap) external {
        pool.setPublicSwap(publicSwap);
    }

    function setSwapFee(AbstractPool pool, uint newFee) external {
        pool.setSwapFee(newFee);
    }

    function setController(AbstractPool pool, address newController) external {
        pool.setController(newController);
    }
    
    // --- Private pool management ---

    function setTokens(
        BPool pool,
        address[] calldata tokens,
        uint[] calldata balances,
        uint[] calldata denorms
    ) external {
        require(tokens.length == balances.length, "ERR_LENGTH_MISMATCH");
        require(tokens.length == denorms.length, "ERR_LENGTH_MISMATCH");

        for (uint i = 0; i < tokens.length; i++) {
            ERC20 token = ERC20(tokens[i]);
            if (pool.isBound(tokens[i])) {
                if (balances[i] > pool.getBalance(tokens[i])) {
                    require(
                        token.transferFrom(msg.sender, address(this), balances[i] - pool.getBalance(tokens[i])),
                        "ERR_TRANSFER_FAILED"
                    );
                    _safeApprove(token, address(pool), balances[i] - pool.getBalance(tokens[i]));
                }
                if (balances[i] > 10**6) {
                    pool.rebind(tokens[i], balances[i], denorms[i]);
                } else {
                    pool.unbind(tokens[i]);
                }

            } else {
                require(token.transferFrom(msg.sender, address(this), balances[i]), "ERR_TRANSFER_FAILED");
                _safeApprove(token, address(pool), balances[i]);
                pool.bind(tokens[i], balances[i], denorms[i]);
            }

            if (token.balanceOf(address(this)) > 0) {
                require(token.transfer(msg.sender, token.balanceOf(address(this))), "ERR_TRANSFER_FAILED");
            }

        }
    }

    function finalize(BPool pool) external {
        pool.finalize();
        require(pool.transfer(msg.sender, pool.balanceOf(address(this))), "ERR_TRANSFER_FAILED");
    }
    
    // --- Smart pool management ---
    
    function increaseWeight(
        ConfigurableRightsPool crp,
        ERC20 token,
        uint newWeight,
        uint tokenAmountIn
    ) external {
        require(token.transferFrom(msg.sender, address(this), tokenAmountIn), "ERR_TRANSFER_FAILED");
        _safeApprove(token, address(crp), tokenAmountIn);
        crp.updateWeight(address(token), newWeight);
        require(crp.transfer(msg.sender, crp.balanceOf(address(this))), "ERR_TRANSFER_FAILED");
    }
    
    function decreaseWeight(
        ConfigurableRightsPool crp,
        ERC20 token,
        uint newWeight,
        uint poolAmountIn
    ) external {
        require(crp.transferFrom(msg.sender, address(this), poolAmountIn), "ERR_TRANSFER_FAILED");
        crp.updateWeight(address(token), newWeight);
        require(token.transfer(msg.sender, token.balanceOf(address(this))), "ERR_TRANSFER_FAILED");
    }
    
    function updateWeightsGradually(
        ConfigurableRightsPool crp,
        uint[] calldata newWeights,
        uint startBlock,
        uint endBlock
    ) external {
        crp.updateWeightsGradually(newWeights, startBlock, endBlock);
    }

    function setCap(
        ConfigurableRightsPool crp,
        uint newCap
    ) external {
        crp.setCap(newCap);
    }

    function commitAddToken(
        ConfigurableRightsPool crp,
        ERC20 token,
        uint balance,
        uint denormalizedWeight
    ) external {
        crp.commitAddToken(address(token), balance, denormalizedWeight);
    }

    function applyAddToken(
        ConfigurableRightsPool crp,
        ERC20 token,
        uint tokenAmountIn
    ) external {
        require(token.transferFrom(msg.sender, address(this), tokenAmountIn), "ERR_TRANSFER_FAILED");
        _safeApprove(token, address(crp), tokenAmountIn);
        crp.applyAddToken();
        require(crp.transfer(msg.sender, crp.balanceOf(address(this))), "ERR_TRANSFER_FAILED");
    }

    function removeToken(
        ConfigurableRightsPool crp,
        ERC20 token,
        uint poolAmountIn
    ) external {
        require(crp.transferFrom(msg.sender, address(this), poolAmountIn), "ERR_TRANSFER_FAILED");
        crp.removeToken(address(token));
        require(token.transfer(msg.sender, token.balanceOf(address(this))), "ERR_TRANSFER_FAILED");
    }

    function whitelistLiquidityProvider(
        ConfigurableRightsPool crp,
        address provider
    ) external {
        crp.whitelistLiquidityProvider(provider);
    }

    function removeWhitelistedLiquidityProvider(
        ConfigurableRightsPool crp,
        address provider
    ) external {
        crp.removeWhitelistedLiquidityProvider(provider);
    }
    
    // --- Internals ---
    
    function _safeApprove(ERC20 token, address spender, uint amount) internal {
        if (token.allowance(address(this), spender) > 0) {
            token.approve(spender, 0);
        }
        token.approve(spender, amount);
    }
    
    function _join(
        AbstractPool pool,
        address[] memory tokens,
        uint poolAmountOut,
        uint[] memory maxAmountsIn
    ) internal {
        require(maxAmountsIn.length == tokens.length, "ERR_LENGTH_MISMATCH");

        for (uint i = 0; i < tokens.length; i++) {
            ERC20 token = ERC20(tokens[i]);
            require(token.transferFrom(msg.sender, address(this), maxAmountsIn[i]), "ERR_TRANSFER_FAILED");
            if (token.allowance(address(this), address(pool)) > 0) {
                token.approve(address(pool), 0);
            }
            token.approve(address(pool), maxAmountsIn[i]);
        }
        pool.joinPool(poolAmountOut, maxAmountsIn);
        for (uint i = 0; i < tokens.length; i++) {
            ERC20 token = ERC20(tokens[i]);
            if (token.balanceOf(address(this)) > 0) {
                require(token.transfer(msg.sender, token.balanceOf(address(this))), "ERR_TRANSFER_FAILED");
            }
        }
        require(pool.transfer(msg.sender, pool.balanceOf(address(this))), "ERR_TRANSFER_FAILED");
    }
}
