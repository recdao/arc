pragma solidity ^0.4.23;

import "./Avatar.sol";
import "./Reputation.sol";
import "./DAOToken.sol";
import "../globalConstraints/GlobalConstraintInterface.sol";
import "./ControllerInterface.sol";


/**
 * @title Controller contract
 * @dev A controller controls the organizations tokens,reputation and avatar.
 * It is subject to a set of schemes and constraints that determine its behavior.
 * Each scheme has it own parameters and operation permissions.
 */
contract Controller is ControllerInterface {

    struct Scheme {
        bytes32 paramsHash;  // a hash "configuration" of the scheme
        bytes4  permissions; // A bitwise flags of permissions,
                             // All 0: Not registered,
                             // 1st bit: Flag if the scheme is registered,
                             // 2nd bit: Scheme can register other schemes
                             // 3rd bit: Scheme can add/remove global constraints
                             // 4th bit: Scheme can upgrade the controller
                             // 5th bit: Scheme can call delegatecall
    }

    struct GlobalConstraint {
        address gcAddress;
        bytes32 params;
    }

    struct GlobalConstraintRegister {
        bool register; //is register
        uint index;    //index at globalConstraints
    }

    mapping(address=>Scheme) public schemes;

    Avatar public avatar;
    DAOToken public nativeToken;
    Reputation public nativeReputation;
  // newController will point to the new controller after the present controller is upgraded
    address public newController;
  // globalConstraintsPre that determine pre conditions for all actions on the controller

    GlobalConstraint[] public globalConstraintsPre;
  // globalConstraintsPost that determine post conditions for all actions on the controller
    GlobalConstraint[] public globalConstraintsPost;
  // globalConstraintsRegisterPre indicate if a globalConstraints is registered as a pre global constraint
    mapping(address=>GlobalConstraintRegister) public globalConstraintsRegisterPre;
  // globalConstraintsRegisterPost indicate if a globalConstraints is registered as a post global constraint
    mapping(address=>GlobalConstraintRegister) public globalConstraintsRegisterPost;

    event MintReputation (address indexed _sender, address indexed _to, uint256 _amount);
    event BurnReputation (address indexed _sender, address indexed _from, uint256 _amount);
    event MintTokens (address indexed _sender, address indexed _beneficiary, uint256 _amount);
    event RegisterScheme (address indexed _sender, address indexed _scheme);
    event UnregisterScheme (address indexed _sender, address indexed _scheme);
    event GenericAction (address indexed _sender, bytes32[] _params);
    event SendEther (address indexed _sender, uint _amountInWei, address indexed _to);
    event ExternalTokenTransfer (address indexed _sender, address indexed _externalToken, address indexed _to, uint _value);
    event ExternalTokenTransferFrom (address indexed _sender, address indexed _externalToken, address _from, address _to, uint _value);
    event ExternalTokenIncreaseApproval (address indexed _sender, StandardToken indexed _externalToken, address _spender, uint _value);
    event ExternalTokenDecreaseApproval (address indexed _sender, StandardToken indexed _externalToken, address _spender, uint _value);
    event UpgradeController(address indexed _oldController,address _newController);
    event AddGlobalConstraint(address indexed _globalConstraint, bytes32 _params,GlobalConstraintInterface.CallPhase _when);
    event RemoveGlobalConstraint(address indexed _globalConstraint ,uint256 _index,bool _isPre);

    constructor( Avatar _avatar) public
    {
        avatar = _avatar;
        nativeToken = avatar.nativeToken();
        nativeReputation = avatar.nativeReputation();
        schemes[msg.sender] = Scheme({paramsHash: bytes32(0),permissions: bytes4(0x1F)});
    }

  // Do not allow mistaken calls:
    function() external {
        revert();
    }

  // Modifiers:
    modifier onlyRegisteredScheme() {
        require(schemes[msg.sender].permissions&bytes4(1) == bytes4(1));
        _;
    }

    modifier onlyRegisteringSchemes() {
        require(schemes[msg.sender].permissions&bytes4(2) == bytes4(2));
        _;
    }

    modifier onlyGlobalConstraintsScheme() {
        require(schemes[msg.sender].permissions&bytes4(4) == bytes4(4));
        _;
    }

    modifier onlyUpgradingScheme() {
        require(schemes[msg.sender].permissions&bytes4(8) == bytes4(8));
        _;
    }

    modifier onlyDelegateScheme() {
        require(schemes[msg.sender].permissions&bytes4(16) == bytes4(16));
        _;
    }

    modifier onlySubjectToConstraint(bytes32 func) {
        uint idx;
        for (idx = 0;idx<globalConstraintsPre.length;idx++) {
            require((GlobalConstraintInterface(globalConstraintsPre[idx].gcAddress)).pre(msg.sender,globalConstraintsPre[idx].params,func));
        }
        _;
        for (idx = 0;idx<globalConstraintsPost.length;idx++) {
            require((GlobalConstraintInterface(globalConstraintsPost[idx].gcAddress)).post(msg.sender,globalConstraintsPost[idx].params,func));
        }
    }

    modifier isAvatarValid(address _avatar) {
        require(_avatar == address(avatar));
        _;
    }

    /**
     * @dev Mint `_amount` of reputation that are assigned to `_to` .
     * @param  _amount amount of reputation to mint
     * @param _to beneficiary address
     * @return bool which represents a success
     */
    function mintReputation(uint256 _amount, address _to,address _avatar)
    external
    onlyRegisteredScheme
    onlySubjectToConstraint("mintReputation")
    isAvatarValid(_avatar)
    returns(bool)
    {
        emit MintReputation(msg.sender, _to, _amount);
        return nativeReputation.mint(_to, _amount);
    }

    /**
     * @dev Burns `_amount` of reputation from `_from`
     * @param _amount amount of reputation to burn
     * @param _from The address that will lose the reputation
     * @return bool which represents a success
     */
    function burnReputation(uint256 _amount, address _from,address _avatar)
    external
    onlyRegisteredScheme
    onlySubjectToConstraint("burnReputation")
    isAvatarValid(_avatar)
    returns(bool)
    {
        emit BurnReputation(msg.sender, _from, _amount);
        return nativeReputation.burn(_from, _amount);
    }

    /**
     * @dev mint tokens .
     * @param  _amount amount of token to mint
     * @param _beneficiary beneficiary address
     * @return bool which represents a success
     */
    function mintTokens(uint256 _amount, address _beneficiary,address _avatar)
    external
    onlyRegisteredScheme
    onlySubjectToConstraint("mintTokens")
    isAvatarValid(_avatar)
    returns(bool)
    {
        emit MintTokens(msg.sender, _beneficiary, _amount);
        return nativeToken.mint(_beneficiary, _amount);
    }

  /**
   * @dev register a scheme
   * @param _scheme the address of the scheme
   * @param _paramsHash a hashed configuration of the usage of the scheme
   * @param _permissions the permissions the new scheme will have
   * @return bool which represents a success
   */
    function registerScheme(address _scheme, bytes32 _paramsHash, bytes4 _permissions,address _avatar)
    external
    onlyRegisteringSchemes
    onlySubjectToConstraint("registerScheme")
    isAvatarValid(_avatar)
    returns(bool)
    {

        Scheme memory scheme = schemes[_scheme];

    // Check scheme has at least the permissions it is changing, and at least the current permissions:
    // Implementation is a bit messy. One must recall logic-circuits ^^

    // produces non-zero if sender does not have all of the perms that are changing between old and new
        require(bytes4(0x1F)&(_permissions^scheme.permissions)&(~schemes[msg.sender].permissions) == bytes4(0));

    // produces non-zero if sender does not have all of the perms in the old scheme
        require(bytes4(0x1F)&(scheme.permissions&(~schemes[msg.sender].permissions)) == bytes4(0));

    // Add or change the scheme:
        schemes[_scheme].paramsHash = _paramsHash;
        schemes[_scheme].permissions = _permissions|bytes4(1);
        emit RegisterScheme(msg.sender, _scheme);
        return true;
    }

    /**
     * @dev unregister a scheme
     * @param _scheme the address of the scheme
     * @return bool which represents a success
     */
    function unregisterScheme( address _scheme,address _avatar)
    external
    onlyRegisteringSchemes
    onlySubjectToConstraint("unregisterScheme")
    isAvatarValid(_avatar)
    returns(bool)
    {
    //check if the scheme is register
        if (schemes[_scheme].permissions&bytes4(1) == bytes4(0)) {
            return false;
          }
    // Check the unregistering scheme has enough permissions:
        require(bytes4(0x1F)&(schemes[_scheme].permissions&(~schemes[msg.sender].permissions)) == bytes4(0));

    // Unregister:
        emit UnregisterScheme(msg.sender, _scheme);
        delete schemes[_scheme];
        return true;
    }

    /**
     * @dev unregister the caller's scheme
     * @return bool which represents a success
     */
    function unregisterSelf(address _avatar) isAvatarValid(_avatar) external returns(bool) {
        if (_isSchemeRegistered(msg.sender,_avatar) == false) {
            return false;
        }
        delete schemes[msg.sender];
        emit UnregisterScheme(msg.sender, msg.sender);
        return true;
    }

    function isSchemeRegistered(address _scheme,address _avatar) isAvatarValid(_avatar) external view returns(bool) {
        return _isSchemeRegistered(_scheme,_avatar);
    }

    function getSchemeParameters(address _scheme,address _avatar) isAvatarValid(_avatar) external view returns(bytes32) {
        return schemes[_scheme].paramsHash;
    }

    function getSchemePermissions(address _scheme,address _avatar) isAvatarValid(_avatar) external view returns(bytes4) {
        return schemes[_scheme].permissions;
    }

   /**
    * @dev globalConstraintsCount return the global constraint pre and post count
    * @return uint globalConstraintsPre count.
    * @return uint globalConstraintsPost count.
    */
    function globalConstraintsCount(address _avatar)
        isAvatarValid(_avatar)
        external
        view
        returns(uint,uint)
        {
        return (globalConstraintsPre.length,globalConstraintsPost.length);
    }

    function isGlobalConstraintRegistered(address _globalConstraint,address _avatar)
        isAvatarValid(_avatar)
        external
        view
        returns(bool)
        {
        return (globalConstraintsRegisterPre[_globalConstraint].register || globalConstraintsRegisterPost[_globalConstraint].register);
    }

    /**
     * @dev add or update Global Constraint
     * @param _globalConstraint the address of the global constraint to be added.
     * @param _params the constraint parameters hash.
     * @return bool which represents a success
     */
    function addGlobalConstraint(address _globalConstraint, bytes32 _params,address _avatar)
    external
    onlyGlobalConstraintsScheme
    isAvatarValid(_avatar)
    returns(bool)
    {
        GlobalConstraintInterface.CallPhase when = GlobalConstraintInterface(_globalConstraint).when();
        if ((when == GlobalConstraintInterface.CallPhase.Pre)||(when == GlobalConstraintInterface.CallPhase.PreAndPost)) {
            if (!globalConstraintsRegisterPre[_globalConstraint].register) {
                globalConstraintsPre.push(GlobalConstraint(_globalConstraint,_params));
                globalConstraintsRegisterPre[_globalConstraint] = GlobalConstraintRegister(true,globalConstraintsPre.length-1);
            }else {
                globalConstraintsPre[globalConstraintsRegisterPre[_globalConstraint].index].params = _params;
            }
        }
        if ((when == GlobalConstraintInterface.CallPhase.Post)||(when == GlobalConstraintInterface.CallPhase.PreAndPost)) {
            if (!globalConstraintsRegisterPost[_globalConstraint].register) {
                globalConstraintsPost.push(GlobalConstraint(_globalConstraint,_params));
                globalConstraintsRegisterPost[_globalConstraint] = GlobalConstraintRegister(true,globalConstraintsPost.length-1);
            }else {
                globalConstraintsPost[globalConstraintsRegisterPost[_globalConstraint].index].params = _params;
            }
        }
        emit AddGlobalConstraint(_globalConstraint, _params,when);
        return true;
    }

    /**
     * @dev remove Global Constraint
     * @param _globalConstraint the address of the global constraint to be remove.
     * @return bool which represents a success
     */
    function removeGlobalConstraint (address _globalConstraint,address _avatar)
    external
    onlyGlobalConstraintsScheme
    isAvatarValid(_avatar)
    returns(bool)
    {
        GlobalConstraintRegister memory globalConstraintRegister;
        GlobalConstraint memory globalConstraint;
        GlobalConstraintInterface.CallPhase when = GlobalConstraintInterface(_globalConstraint).when();
        bool retVal = false;

        if ((when == GlobalConstraintInterface.CallPhase.Pre)||(when == GlobalConstraintInterface.CallPhase.PreAndPost)) {
            globalConstraintRegister = globalConstraintsRegisterPre[_globalConstraint];
            if (globalConstraintRegister.register) {
                if (globalConstraintRegister.index < globalConstraintsPre.length-1) {
                    globalConstraint = globalConstraintsPre[globalConstraintsPre.length-1];
                    globalConstraintsPre[globalConstraintRegister.index] = globalConstraint;
                    globalConstraintsRegisterPre[globalConstraint.gcAddress].index = globalConstraintRegister.index;
                }
                globalConstraintsPre.length--;
                delete globalConstraintsRegisterPre[_globalConstraint];
                retVal = true;
            }
        }
        if ((when == GlobalConstraintInterface.CallPhase.Post)||(when == GlobalConstraintInterface.CallPhase.PreAndPost)) {
            globalConstraintRegister = globalConstraintsRegisterPost[_globalConstraint];
            if (globalConstraintRegister.register) {
                if (globalConstraintRegister.index < globalConstraintsPost.length-1) {
                    globalConstraint = globalConstraintsPost[globalConstraintsPost.length-1];
                    globalConstraintsPost[globalConstraintRegister.index] = globalConstraint;
                    globalConstraintsRegisterPost[globalConstraint.gcAddress].index = globalConstraintRegister.index;
                }
                globalConstraintsPost.length--;
                delete globalConstraintsRegisterPost[_globalConstraint];
                retVal = true;
            }
        }
        if (retVal) {
            emit RemoveGlobalConstraint(_globalConstraint,globalConstraintRegister.index,when == GlobalConstraintInterface.CallPhase.Pre);
        }
        return retVal;
    }

  /**
    * @dev upgrade the Controller
    *      The function will trigger an event 'UpgradeController'.
    * @param  _newController the address of the new controller.
    * @return bool which represents a success
    */
    function upgradeController(address _newController,address _avatar)
    external
    onlyUpgradingScheme
    isAvatarValid(_avatar)
    returns(bool)
    {
        require(newController == address(0));   // so the upgrade could be done once for a contract.
        require(_newController != address(0));
        newController = _newController;
        avatar.transferOwnership(_newController);
        require(avatar.owner()==_newController);
        if (nativeToken.owner() == address(this)) {
            nativeToken.transferOwnership(_newController);
            require(nativeToken.owner()==_newController);
        }
        if (nativeReputation.owner() == address(this)) {
            nativeReputation.transferOwnership(_newController);
            require(nativeReputation.owner()==_newController);
        }
        emit UpgradeController(this,newController);
        return true;
    }

    /**
    * @dev do a generic delegate call to the contract which called us.
    * This function use delegatecall and might expose the organization to security
    * risk. Use this function only if you really knows what you are doing.
    * @param _params the params for the call.
    * @return bool which represents success
    */
    function genericAction(bytes32[] _params,address _avatar)
    external
    onlyDelegateScheme
    onlySubjectToConstraint("genericAction")
    isAvatarValid(_avatar)
    returns(bool)
    {
        emit GenericAction(msg.sender, _params);
        return avatar.genericAction(msg.sender, _params);
    }

  /**
   * @dev send some ether
   * @param _amountInWei the amount of ether (in Wei) to send
   * @param _to address of the beneficiary
   * @return bool which represents a success
   */
    function sendEther(uint _amountInWei, address _to,address _avatar)
    external
    onlyRegisteredScheme
    onlySubjectToConstraint("sendEther")
    isAvatarValid(_avatar)
    returns(bool)
    {
        emit SendEther(msg.sender, _amountInWei, _to);
        return avatar.sendEther(_amountInWei, _to);
    }

    /**
    * @dev send some amount of arbitrary ERC20 Tokens
    * @param _externalToken the address of the Token Contract
    * @param _to address of the beneficiary
    * @param _value the amount of ether (in Wei) to send
    * @return bool which represents a success
    */
    function externalTokenTransfer(StandardToken _externalToken, address _to, uint _value,address _avatar)
    external
    onlyRegisteredScheme
    onlySubjectToConstraint("externalTokenTransfer")
    isAvatarValid(_avatar)
    returns(bool)
    {
        emit ExternalTokenTransfer(msg.sender, _externalToken, _to, _value);
        return avatar.externalTokenTransfer(_externalToken, _to, _value);
    }

    /**
    * @dev transfer token "from" address "to" address
    *      One must to approve the amount of tokens which can be spend from the
    *      "from" account.This can be done using externalTokenApprove.
    * @param _externalToken the address of the Token Contract
    * @param _from address of the account to send from
    * @param _to address of the beneficiary
    * @param _value the amount of ether (in Wei) to send
    * @return bool which represents a success
    */
    function externalTokenTransferFrom(StandardToken _externalToken, address _from, address _to, uint _value,address _avatar)
    external
    onlyRegisteredScheme
    onlySubjectToConstraint("externalTokenTransferFrom")
    isAvatarValid(_avatar)
    returns(bool)
    {
        emit ExternalTokenTransferFrom(msg.sender, _externalToken, _from, _to, _value);
        return avatar.externalTokenTransferFrom(_externalToken, _from, _to, _value);
    }

    /**
    * @dev increase approval for the spender address to spend a specified amount of tokens
    *      on behalf of msg.sender.
    * @param _externalToken the address of the Token Contract
    * @param _spender address
    * @param _addedValue the amount of ether (in Wei) which the approval is referring to.
    * @return bool which represents a success
    */
    function externalTokenIncreaseApproval(StandardToken _externalToken, address _spender, uint _addedValue,address _avatar)
    external
    onlyRegisteredScheme
    onlySubjectToConstraint("externalTokenIncreaseApproval")
    isAvatarValid(_avatar)
    returns(bool)
    {
        emit ExternalTokenIncreaseApproval(msg.sender,_externalToken,_spender,_addedValue);
        return avatar.externalTokenIncreaseApproval(_externalToken, _spender, _addedValue);
    }

    /**
    * @dev decrease approval for the spender address to spend a specified amount of tokens
    *      on behalf of msg.sender.
    * @param _externalToken the address of the Token Contract
    * @param _spender address
    * @param _subtractedValue the amount of ether (in Wei) which the approval is referring to.
    * @return bool which represents a success
    */
    function externalTokenDecreaseApproval(StandardToken _externalToken, address _spender, uint _subtractedValue,address _avatar)
    external
    onlyRegisteredScheme
    onlySubjectToConstraint("externalTokenDecreaseApproval")
    isAvatarValid(_avatar)
    returns(bool)
    {
        emit ExternalTokenDecreaseApproval(msg.sender,_externalToken,_spender,_subtractedValue);
        return avatar.externalTokenDecreaseApproval(_externalToken, _spender, _subtractedValue);
    }

    /**
     * @dev getNativeReputation
     * @param _avatar the organization avatar.
     * @return organization native reputation
     */
    function getNativeReputation(address _avatar) isAvatarValid(_avatar) external view returns(address) {
        return address(nativeReputation);
    }

    function _isSchemeRegistered(address _scheme,address _avatar) isAvatarValid(_avatar) private view returns(bool) {
        return (schemes[_scheme].permissions&bytes4(1) != bytes4(0));
    }
}
