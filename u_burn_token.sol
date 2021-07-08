// SPDX-License-Identifier: SimPL-2.0
pragma solidity ^0.7.6;

import "./oracle/MDEXOracle.sol";

/**
 * Math operations with safety checks
 */
contract SafeMath {
    function safeMul(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a * b;
        assert(a == 0 || c / a == b);
        return c;
    }

    function safeDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        assert(b > 0);
        uint256 c = a / b;
        assert(a == b * c + (a % b));
        return c;
    }

    function safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        assert(b <= a);
        return a - b;
    }

    function safeAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        assert(c >= a && c >= b);
        return c;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }
}

contract u_burn_token is SafeMath {
    string public name;
    string public symbol;
    uint8 public decimals = 3;
    uint256 public epoch_base = 86400; //挖矿周期基数，不变

    uint256 public totalSupply;
    uint256 public totalPower; //总算力
    uint256 public totalUsersAmount; //总用户数
    address payable public owner;

    address public upgradedAddress; //升级的新合约地址
    bool public deprecated = false; //是否升级到新合约

    mapping(address => bool) public burn_swap_address; //交易所地址
    MDEXOracle private bt_oracle; //价格预言机

    uint256 public burn_price; //烧伤价格

    uint256 public decimal_bt = 1000;
    uint256 public decimal_usdt = 1000000000000000000;

    /* -- other variables -- */

    /* This creates an array with all balances */
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public CoinBalanceOf;
    //      user             token        balance
    mapping(address => mapping(address => uint256)) public TokenBalanceOf;
    mapping(address => address) public invite; //邀请
    mapping(address => uint256) public power; //算力
    mapping(address => uint256) public last_miner; //用户上次挖矿时间
    mapping(address => uint256) public users_epoch; //用户挖矿周期，随着时间变化
    mapping(address => uint256) public users_start_time; //用户挖矿开始时间

    mapping(address => uint256) public inviteCount; //邀请人好友数
    mapping(address => uint256) public rewardCount; //累计奖励
    mapping(address => mapping(address => uint256)) public allowance; //授权

    /* This generates a public event on the blockchain that will notify clients */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /* This notifies clients about the amount burnt */
    event Burn(address indexed from, uint256 value);

    /* This notifies clients about the amount frozen */
    event Freeze(address indexed from, uint256 value);

    // 铸币事件
    event Minted(address indexed operator, address indexed to, uint256 amount);

    /* Initializes contract with initial supply tokens to the creator of the contract */
    constructor(
        string memory tokenName,
        string memory tokenSymbol,
        uint256 epoch_time,
        uint256 _burn_price,
        uint256 _decimal_usdt
    ) {
        name = tokenName; // Set the name for display purposes
        symbol = tokenSymbol; // Set the symbol for display purposes
        owner = msg.sender;
        epoch_base = epoch_time;
        deprecated = false;
        burn_price = _burn_price;
        decimal_usdt = _decimal_usdt;

        //团队200万(其中100W用于建立初始流动池)，投资者100万
        balanceOf[msg.sender] = 3000000 * decimal_bt;
        totalSupply = 3000000 * decimal_bt;
    }

    receive() external payable {}

    //设置交易所地址
    function set_swap_address(address _swap_address) public {
        require(msg.sender == owner);
        require(_swap_address != address(0));
        require(isContract(_swap_address));
        burn_swap_address[_swap_address] = !burn_swap_address[_swap_address];
    }

    //设置预言机地址
    function setOracle(address _oracle_address) public {
        require(msg.sender == owner);
        require(_oracle_address != address(0));
        require(isContract(_oracle_address));
        bt_oracle = MDEXOracle(_oracle_address);
    }

    //从预言机获取兑换价格
    // 价值u / ubt个数
    function getSwapPrice(uint256 value) public view returns (uint256) {
        require(value > 0, "amount error");
        uint256 amount = bt_oracle.getAmountOut(value);
        require(amount > 0, "price error");

        uint256 price = SafeMath.safeDiv(amount, value);
        return price;
    }

    //更新烧伤价格
    function update_burn_price() public returns (bool success) {
        require(msg.sender == owner);
        // 烧伤价格=max(当前价格*0.8，上一次烧伤价格)
        uint256 curr_price = bt_oracle.consult(address(this), 1 * decimal_bt);
        require(curr_price > 0, "price error");

        burn_price = SafeMath.max((curr_price * 80) / 100, burn_price);
        return true;
    }

    //自动更新预言机价格及烧伤价格
    function auto_update_burn_price() public returns (bool success) {
        require(msg.sender == owner);
        // 烧伤价格=max(当前价格*0.8，上一次烧伤价格)
        bt_oracle.update();
        update_burn_price();
        return true;
    }

    function withdraw(uint256 amount) public {
        require(msg.sender == owner);
        owner.transfer(amount);
    }

    /* Send coins */
    function transfer(address _to, uint256 _value)
        public
        returns (bool success)
    {
        require(_to != address(0)); // Prevent transfer to 0x0 address. Use burn() instead
        require(_value > 0);
        require(msg.sender != _to); //自己不能转给自己

        uint256 fee = transfer_fee(msg.sender, _to, _value);
        uint256 sub_value = SafeMath.safeAdd(fee, _value); //扣除余额需要计算手续费

        uint256 changedAmount = SafeMath.safeAdd(balanceOf[_to], _value); // Add the same to the recipient
        require(balanceOf[msg.sender] >= sub_value); //需要计算加上手续费后是否够
        if (changedAmount < balanceOf[_to]) revert("overflows"); // Check for overflows

        balanceOf[msg.sender] = SafeMath.safeSub(
            balanceOf[msg.sender],
            sub_value
        ); // Subtract from the sender

        balanceOf[_to] = changedAmount; // Add the same to the recipient
        totalSupply = SafeMath.safeSub(totalSupply, fee); //总量减少手续费
        emit Transfer(msg.sender, _to, _value); // Notify anyone listening that this transfer took place
        if (fee > 0) emit Burn(msg.sender, fee);
        return true;
    }

    function transfer_fee(
        address _from,
        address _to,
        uint256 _value
    ) public view returns (uint256 fee) {
        uint8 scale = 20; // n/100
        //没有挖矿用户免手续费
        if (last_miner[_from] == 0) {
            scale = 0;
            return 0;
        }

        if (power[_from] < 500 * decimal_usdt) {
            scale = 50;
        } else {
            scale = 10;
        }

        //转账到账数量=实际扣除数量*(1-手续费率)
        //手续费=实际扣除数量*手续费率
        //实际扣除数量=转账到账数量/(1-手续费率)
        // uint256 _fee = (_value * scale) / (100 - scale);
        uint256 _fee = SafeMath.safeDiv(
            SafeMath.safeMul(_value, scale),
            (100 - scale)
        );

        // scale 满足烧伤机制 流动池卖出将额外销毁10%
        // 如果 是流动池卖出 且 当前价格<烧伤价格 ，（烧伤价格-当前价格）/烧伤价格 *10 就是额外的手续费
        if (burn_swap_address[_to] == true) {
            uint256 curr_price = getSwapPrice(_value);
            if (curr_price < burn_price) {
                // (2 - 1.5) * 10 * 100 / 2 = 250
                // uint256 burn_fee = ((burn_price - curr_price) * 10 * _value) / burn_price;
                uint256 burn_fee = SafeMath.safeDiv(
                    SafeMath.safeMul((burn_price - curr_price) * 10, _value),
                    burn_price
                );

                _fee = SafeMath.safeAdd(burn_fee, fee);
            }
        }

        return _fee;
    }

    /* Allow another contract to spend some tokens in your behalf */
    function approve(address _spender, uint256 _value)
        public
        returns (bool success)
    {
        // To change the approve amount you first have to reduce the addresses`
        //  allowance to zero by calling `approve(_spender, 0)` if it is not
        //  already 0 to mitigate the race condition described here:
        //  https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
        require(!((_value != 0) && (allowance[msg.sender][_spender] != 0)));

        allowance[msg.sender][_spender] = _value;
        return true;
    }

    /* A contract attempts to get the coins */
    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) public returns (bool success) {
        require(_to != address(0)); // Prevent transfer to 0x0 address. Use burn() instead
        require(_value > 0);
        require(_from != _to); //自己不能转给自己

        uint256 fee = transfer_fee(_from, _to, _value);
        uint256 sub_value = SafeMath.safeAdd(fee, _value);
        uint256 changedAmount = SafeMath.safeAdd(balanceOf[_to], _value); // Add the same to the recipient

        require(balanceOf[_from] >= sub_value); // Check if the sender has enough
        require(changedAmount >= balanceOf[_to]); // Check for overflows
        require(sub_value <= allowance[_from][msg.sender]); // Check allowance

        balanceOf[_from] = SafeMath.safeSub(balanceOf[_from], sub_value); // Subtract from the sender
        balanceOf[_to] = changedAmount; // Add the same to the recipient
        allowance[_from][msg.sender] = SafeMath.safeSub(
            allowance[_from][msg.sender],
            sub_value
        );
        totalSupply = SafeMath.safeSub(totalSupply, fee); //总量减少手续费
        emit Transfer(_from, _to, _value);
        if (fee > 0) emit Burn(_from, fee);
        return true;
    }

    function burn(uint256 _value) public returns (bool success) {
        require(!isContract(msg.sender), "contract address call error");
        require(balanceOf[msg.sender] >= _value); // 检查余额
        require(_value > 0);
        balanceOf[msg.sender] = SafeMath.safeSub(balanceOf[msg.sender], _value); // 减少余额
        totalSupply = SafeMath.safeSub(totalSupply, _value); // 燃烧销毁减少总量
        if (power[msg.sender] == 0) totalUsersAmount++; //累计挖矿用户数

        if (last_miner[msg.sender] == 0) {
            users_epoch[msg.sender] = epoch_base;
        }

        uint256 amount = bt_oracle.getAmountOut(_value); //燃烧UBT的价值
        require(amount > 0, "price error");

        //避免用户获得超额奖励
        if (power[msg.sender] > 0) {
            if (
                (block.timestamp - last_miner[msg.sender]) >=
                users_epoch[msg.sender]
            ) {
                mint();
            }
        }

        //算力燃烧的1%将奖励给开发团队，用于项目维护、发展以及生态建设
        uint256 rewardAmount = SafeMath.safeDiv(_value, 100);
        balanceOf[owner] = SafeMath.safeAdd(balanceOf[owner], rewardAmount); //增加团队奖励
        totalSupply = SafeMath.safeAdd(totalSupply, rewardAmount); //增加总量

        uint256 addPower = SafeMath.safeMul(amount, 3);
        power[msg.sender] = SafeMath.safeAdd(power[msg.sender], addPower); //燃烧加3倍算力
        emit Burn(msg.sender, amount);
        totalPower = SafeMath.safeAdd(totalPower, addPower); //累计总算力
        reward_upline(amount, SafeMath.safeDiv(amount, _value)); //给上级奖励
        return true;
    }

    function reward_upline(uint256 _value, uint256 price)
        private
        returns (bool success)
    {
        //邀请人不能为空
        if (invite[msg.sender] != address(0)) {
            //只有1级奖励
            address invite1 = invite[msg.sender];

            //只有高级矿工才有邀请奖励-帮助转换算力
            if (power[invite1] < 500 * decimal_usdt) {
                return true;
            } else {
                uint8 scale = 5; // n/100 通证数量乘以精度单位

                //小数支持不好，就先乘后除的方法
                //uint256 reward = (_value * scale) / 100;
                uint256 reward = SafeMath.safeDiv(
                    SafeMath.safeMul(_value, scale),
                    100
                );

                //如果本次转换算力大于上级剩余算力
                if (power[invite1] < reward) {
                    reward = power[invite1];
                }

                // reward / 流动池价格
                uint256 rewardAmount = SafeMath.safeDiv(reward, price);

                power[invite1] = power[invite1] - reward; //减少邀请人算力
                totalPower = SafeMath.safeSub(totalPower, reward); //减少总算力
                balanceOf[invite1] = SafeMath.safeAdd(
                    balanceOf[invite1],
                    rewardAmount
                ); //增加邀请人余额
                totalSupply = SafeMath.safeAdd(totalSupply, rewardAmount); //增加总量
                rewardCount[invite1] = SafeMath.safeAdd(
                    rewardCount[invite1],
                    rewardAmount
                ); //记录累计奖励
                emit Minted(msg.sender, invite1, rewardAmount);
            }
        }
        return true;
    }

    // 判断地址是否为合约
    function isContract(address addr) internal view returns (bool) {
        uint256 size;
        if (addr == address(0)) return false;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    function setOwner(address payable new_owner) public {
        require(msg.sender == owner);
        require(owner != address(0));
        owner = new_owner;
    }

    function update_epoch() private returns (bool success) {
        if (last_miner[msg.sender] == 0) {
            users_start_time[msg.sender] = block.timestamp;
        }
        users_epoch[msg.sender] = SafeMath.safeAdd(
            epoch_base,
            SafeMath.safeDiv(
                (block.timestamp - users_start_time[msg.sender]),
                365
            )
        );
        return true;
    }

    function registration(address invite_address)
        public
        returns (bool success)
    {
        require(invite[msg.sender] == address(0)); //现在没有邀请人
        require(msg.sender != invite_address); //不能是自己
        invite[msg.sender] = invite_address; //记录邀请人
        inviteCount[invite_address] += 1; //邀请人的下级数加一
        return true;
    }

    //挖矿可领取的奖励
    function mint_reward()
        public
        view
        returns (uint256 usePower, uint256 amount)
    {
        require(!isContract(msg.sender), "contract address call error");
        require(power[msg.sender] > 0); //算力不能为零
        require(
            block.timestamp - last_miner[msg.sender] >= users_epoch[msg.sender]
        ); //距离上次挖矿大于一个周期

        //每次挖矿释放算力余额的0.5%
        uint8 scale = 50; // 万分之n
        // uint256 miner_days = (block.timestamp - last_miner[msg.sender]) / users_epoch[msg.sender];
        uint256 miner_days = SafeMath.safeDiv(
            (block.timestamp - last_miner[msg.sender]),
            users_epoch[msg.sender]
        );

        if (miner_days > 30) {
            miner_days = 30; //单次最多领取30天的
        }

        //第一次挖矿只能1天
        if (last_miner[msg.sender] == 0) {
            miner_days = 1;
        }

        //v2及以上可以30天 v1只能每天领
        if (miner_days > 1 && power[msg.sender] < 500 * decimal_usdt) {
            miner_days = 1;
        }

        //算力*比例*天数
        // reward * 流动池价格
        uint256 reward = SafeMath.safeDiv(
            SafeMath.safeMul(power[msg.sender], miner_days * scale),
            10000
        );
        uint256 swap_price = getSwapPrice(
            SafeMath.safeDiv(reward, SafeMath.safeDiv(decimal_usdt, decimal_bt))
        );
        uint256 rewardAmount = SafeMath.safeDiv(reward, swap_price);
        return (reward, rewardAmount);
    }

    function mint() public returns (bool success) {
        (uint256 reward, uint256 rewardAmount) = mint_reward();
        update_epoch(); //每次都更新基础周期值

        power[msg.sender] = SafeMath.safeSub(power[msg.sender], reward); //算力减去本次转换的
        totalPower = SafeMath.safeSub(totalPower, reward); //减少总算力
        balanceOf[msg.sender] = SafeMath.safeAdd(
            balanceOf[msg.sender],
            rewardAmount
        ); //增加余额
        totalSupply = SafeMath.safeAdd(totalSupply, rewardAmount); //增加总量
        last_miner[msg.sender] = block.timestamp; //记录本次挖矿时间
        emit Transfer(address(0), msg.sender, rewardAmount);
        return true;
    }
}
