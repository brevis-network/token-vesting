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

    function getVestingCompleteInfo(address[] calldata _beneficiaries)
        external
        view
        returns (
            uint256[] memory allocations,
            uint256[] memory vestedAmounts,
            uint256[] memory releasedAmounts,
            uint256[] memory releasableAmounts
        )
    {
        uint256 n = _beneficiaries.length;
        allocations = new uint256[](n);
        vestedAmounts = new uint256[](n);
        releasedAmounts = new uint256[](n);
        releasableAmounts = new uint256[](n);

        for (uint256 i = 0; i < n; ++i) {
            address b = _beneficiaries[i];
            uint256 alloc = vestingContract.allocations(b);
            uint256 vested = vestingContract.vestingSchedule(b);
            uint256 rel = vestingContract.released(b);

            allocations[i] = alloc;
            vestedAmounts[i] = vested;
            releasedAmounts[i] = rel;
            // Compute releasable as vested - released to avoid requiring an extra interface method
            releasableAmounts[i] = vested - rel;
        }
    }
}

interface ITokenVesting {
    function vestingSchedule(address _beneficiary) external view returns (uint256);
    function released(address _beneficiary) external view returns (uint256);
    function allocations(address _beneficiary) external view returns (uint256);
}
