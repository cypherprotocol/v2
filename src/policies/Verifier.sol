import { DefaultRegistry } from "../modules/RSTRY.sol";
import { DefaultHardwareStack } from "../modules/STACK.sol";
import { Kernel, Policy, Permissions, Keycode } from "../Kernel.sol";
import { toKeycode } from "../utils/KernelUtils.sol";

pragma solidity ^0.8.15;

interface IVerifier {
    error NotAssignedVerifier();
}

contract Verifier is Policy, IVerifier {
    /////////////////////////////////////////////////////////////////////////////////
    //                         Kernel Policy Configuration                         //
    /////////////////////////////////////////////////////////////////////////////////

    DefaultRegistry public RSTRY;
    DefaultHardwareStack public STACK;

    constructor(Kernel kernel_) Policy(kernel_) {}

    function configureDependencies()
        external
        override
        onlyKernel
        returns (Keycode[] memory dependencies)
    {
        dependencies = new Keycode[](2);

        dependencies[0] = toKeycode("RSTRY");
        dependencies[1] = toKeycode("STACK");
        RSTRY = DefaultRegistry(getModuleAddress(toKeycode("RSTRY")));
        STACK = DefaultHardwareStack(getModuleAddress(toKeycode("STACK")));
    }

    function requestPermissions()
        external
        view
        override
        onlyKernel
        returns (Permissions[] memory requests)
    {
        requests = new Permissions[](1);
        requests[0] = Permissions(toKeycode("STACK"), STACK.executeCallFromStack.selector);
    }

    modifier onlyVerifier(bytes32 userId) {
        if (msg.sender == RSTRY.getVerifierForUserId(userId)) revert NotAssignedVerifier();
        _;
    }

    function executeCallFromStack(bytes32 userId) external onlyVerifier(userId) {
        STACK.executeCallFromStack(userId);
    }
}
