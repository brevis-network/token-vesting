// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract VestingViewer {
    ITokenVesting public vestingContract;

    constructor(address _vestingContract) {
        vestingContract = ITokenVesting(_vestingContract);
    }

    /**
     * @notice Batch fetch vested and released amounts for multiple beneficiaries.
     * @dev Uses the existing TokenVesting interface; no state changes.
     * @param _beneficiaries Array of beneficiary addresses to query.
     * @return vestedAmounts Array of current vested amounts for each beneficiary.
     * @return releasedAmounts Array of total released amounts for each beneficiary.
     */
    function getVestingInfo(address[] calldata _beneficiaries)
        external
        view
        returns (uint256[] memory vestedAmounts, uint256[] memory releasedAmounts)
    {
        uint256 n = _beneficiaries.length;
        vestedAmounts = new uint256[](n);
        releasedAmounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            address b = _beneficiaries[i];
            vestedAmounts[i] = vestingContract.vestingSchedule(b);
            releasedAmounts[i] = vestingContract.released(b);
        }
    }
}

interface ITokenVesting {
    function vestingSchedule(address _beneficiary) external view returns (uint256);
    function released(address _beneficiary) external view returns (uint256);
}
