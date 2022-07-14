// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

// ######################## ~ ERRORS ~ ########################

// MODULE

error Module_PolicyNotAuthorized();

// POLICY

error Policy_ModuleDoesNotExist(Kernel.Keycode keycode_);
error Policy_OnlyKernel(address caller_);

// KERNEL

error Kernel_OnlyExecutor(address caller_);
error Kernel_ModuleAlreadyInstalled(Kernel.Keycode module_);
error Kernel_ModuleAlreadyExists(Kernel.Keycode module_);
error Kernel_PolicyAlreadyApproved(address policy_);
error Kernel_PolicyNotApproved(address policy_);

// ######################## ~ GLOBAL TYPES ~ ########################

enum Actions {
    InstallModule,
    UpgradeModule,
    ApprovePolicy,
    TerminatePolicy,
    ChangeExecutor
}

struct Instruction {
    Actions action;
    address target;
}

struct RequestPermissions {
    Kernel.Keycode keycode;
    bytes4 funcSelector;
}

// ######################## ~ MODULE ABSTRACT ~ ########################

abstract contract Module {
    Kernel public kernel;

    constructor(Kernel kernel_) {
        kernel = kernel_;
    }

    modifier permissioned(bytes4 funcSelector_) {
      Kernel.Keycode keycode = KEYCODE();
      if (kernel.policyPermissions(msg.sender, keycode, funcSelector_) == false) {
        revert Module_PolicyNotAuthorized();
      }
      _;
    }

    function KEYCODE() public pure virtual returns (Kernel.Keycode);

    /// @notice Specify which version of a module is being implemented.
    /// @dev Minor version change retains interface. Major version upgrade indicates
    ///      breaking change to the interface.
    function VERSION()
        external
        pure
        virtual
        returns (uint8 major, uint8 minor)
    {}
}

abstract contract Policy {
    Kernel public kernel;
    
    mapping(Kernel.Keycode => bool) public hasDependency;


    constructor(Kernel kernel_) {
        kernel = kernel_;
    }

    modifier onlyKernel() {
        if (msg.sender != address(kernel)) revert Policy_OnlyKernel(msg.sender);
        _;
    }

    function _toKeycode(bytes5 keycode_) internal pure returns (Kernel.Keycode keycode) {
        keycode = Kernel.Keycode.wrap(keycode_);
    }

    function registerDependency(Kernel.Keycode keycode_) 
      external 
      onlyKernel  
    {
        hasDependency[keycode_] = true;
    }

    function updateDependencies() 
      external 
      virtual 
      onlyKernel 
      returns (Kernel.Keycode[] memory dependencies) 
    {}

    function requestPermissions()
        external
        view
        virtual
        returns (RequestPermissions[] memory requests)
    {}

    function getModuleAddress(Kernel.Keycode keycode_) internal view returns (address) {
        address moduleForKeycode = kernel.getModuleForKeycode(keycode_);

        if (moduleForKeycode == address(0))
            revert Policy_ModuleDoesNotExist(keycode_);

        return moduleForKeycode;
    }
}

contract Kernel {
    // ######################## ~ VARS ~ ########################

    type Keycode is bytes5;
    address public executor;

    // ######################## ~ DEPENDENCY MANAGEMENT ~ ########################

    mapping(Keycode => address) public getModuleForKeycode; // get contract for module keycode
    mapping(address => Keycode) public getKeycodeForModule; // get module keycode for contract
    mapping(address => mapping(Keycode => mapping(bytes4 => bool))) public policyPermissions; // for policy addr, check if they have permission to call the function int he module
    
    address[] public allPolicies;


    // ######################## ~ EVENTS ~ ########################

    event PermissionsUpated(
        address indexed policy_,
        Keycode indexed keycode_,
        bytes4 funcSelector_,
        bool indexed granted_
    );

    event ActionExecuted(Actions indexed action_, address indexed target_);

    // ######################## ~ BODY ~ ########################

    constructor() {
        executor = msg.sender;
    }

    // ######################## ~ MODIFIERS ~ ########################

    modifier onlyExecutor() {
        if (msg.sender != executor) revert Kernel_OnlyExecutor(msg.sender);
        _;
    }

    // ######################## ~ KERNEL INTERFACE ~ ########################

    function executeAction(Actions action_, address target_)
        external
        onlyExecutor
    {
        if (action_ == Actions.InstallModule) {
            _installModule(target_);
        } else if (action_ == Actions.UpgradeModule) {
            _upgradeModule(target_);
        } else if (action_ == Actions.ApprovePolicy) {
            _approvePolicy(target_);
        } else if (action_ == Actions.TerminatePolicy) {
            _terminatePolicy(target_);
        } else if (action_ == Actions.ChangeExecutor) {
            executor = target_;
        }

        emit ActionExecuted(action_, target_);
    }

    // ######################## ~ KERNEL INTERNAL ~ ########################

    function _installModule(address newModule_) internal {
        Keycode keycode = Module(newModule_).KEYCODE();

        // @NOTE check newModule_ != 0
        if (getModuleForKeycode[keycode] != address(0))
            revert Kernel_ModuleAlreadyInstalled(keycode);

        getModuleForKeycode[keycode] = newModule_;
        getKeycodeForModule[newModule_] = keycode;
    }

    function _upgradeModule(address newModule_) internal {
        Keycode keycode = Module(newModule_).KEYCODE();
        address oldModule = getModuleForKeycode[keycode];

        if (oldModule == address(0) || oldModule == newModule_)
            revert Kernel_ModuleAlreadyExists(keycode);

        getKeycodeForModule[oldModule] = Keycode.wrap(bytes5(0));
        getKeycodeForModule[newModule_] = keycode;
        getModuleForKeycode[keycode] = newModule_;

        // go through each policy in the Kernel and update its dependencies if they include the module
        for (uint i; i < allPolicies.length; ) {
            address policy = allPolicies[i];
            if (Policy(policy).hasDependency(keycode)) {
                Policy(policy).updateDependencies();
            }
        }
    }

    function _approvePolicy(address policy_) internal {
        Policy(policy_).updateDependencies();
        RequestPermissions[] memory requests = Policy(policy_).requestPermissions();
        
        for (uint256 i = 0; i < requests.length; ) {
            RequestPermissions memory request = requests[i];

            policyPermissions[policy_][request.keycode][request.funcSelector] = true;

            Policy(policy_).registerDependency(request.keycode);

            emit PermissionsUpated(policy_, request.keycode, request.funcSelector, true);

            unchecked { i++; }

        }

        allPolicies.push(policy_);
    }

    function _terminatePolicy(address policy_) internal {

        RequestPermissions[] memory requests = Policy(policy_).requestPermissions();

        for (uint256 i = 0; i < requests.length; ) {
            RequestPermissions memory request = requests[i];

            policyPermissions[policy_][request.keycode][request.funcSelector] = false;

            emit PermissionsUpated(policy_, request.keycode, request.funcSelector, false);

            unchecked { i++; }
        }

        // swap the current policy (terminated) with the last policy in the list and remove the last item
        uint numPolicies = allPolicies.length;

        for (uint j; j < numPolicies;) {
            if (allPolicies[j] == policy_) {
              allPolicies[j] = allPolicies[numPolicies - 1]; 
              allPolicies.pop();
            }
        }
    }
}