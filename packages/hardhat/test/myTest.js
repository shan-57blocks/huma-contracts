/* eslint-disable no-underscore-dangle */
const { ethers } = require("hardhat");
const { use, expect } = require("chai");
const { solidity } = require("ethereum-waffle");

use(solidity);

const getLoanContractFromAddress = async function (address, signer) {
    return ethers.getContractAt("HumaLoan", address, signer);
};

describe("Base Contracts", function () {
    let humaPoolAdminsContract;
    let humaPoolFactoryContract;
    let humaPoolContract;
    let humaConfigContract;
    let testTokenContract;
    let owner;
    let lender;
    let borrower;
    let borrower2;

    before(async function () {
        [owner, lender, borrower, borrower2] = await ethers.getSigners();

        const HumaPoolAdmins = await ethers.getContractFactory(
            "HumaPoolAdmins"
        );
        humaPoolAdminsContract = await HumaPoolAdmins.deploy();

        const HumaConfig = await ethers.getContractFactory("HumaConfig");
        humaConfigContract = await HumaConfig.deploy(
            owner.address,
            owner.address
        );

        const HumaPoolFactory = await ethers.getContractFactory(
            "HumaPoolFactory"
        );
        humaPoolFactoryContract = await HumaPoolFactory.deploy(
            humaPoolAdminsContract.address,
            humaConfigContract.address
        );

        const TestToken = await ethers.getContractFactory("TestToken");
        testTokenContract = await TestToken.deploy();
    });

    describe("Deployment", function () {
        it("Should have correct owners", async function () {
            expect(await humaPoolAdminsContract.owner()).to.equal(
                owner.address
            );
        });
    });

    describe("HumaConfig", function () {
        it("Should show the right governor", async function () {
            expect(await humaConfigContract.getGovernor()).to.equal(
                owner.address
            );
        });
        it("Should show the right treasury address", async function () {
            expect(await humaConfigContract.getHumaTreasury()).to.equal(
                owner.address
            );
        });
        it("Update treasury fee", async function () {
            await humaConfigContract.setTreasuryFee(50);
            expect(await humaConfigContract.treasuryFee()).to.equal(50);
        });
    });

    describe("HumaPoolAdmins", function () {
        it("Only huma master admin can create new pools", async function () {
            await testTokenContract.approve(
                humaPoolFactoryContract.address,
                99999
            );
            await expect(
                humaPoolFactoryContract.deployNewPool(
                    testTokenContract.address,
                    100
                )
            ).to.emit(humaPoolFactoryContract, "PoolDeployed");
        });

        it("Other users cannot create new pools", async function () {
            await testTokenContract
                .connect(borrower)
                .approve(humaPoolFactoryContract.address, 99999);
            await testTokenContract.approve(
                humaPoolFactoryContract.address,
                99999
            );
            await expect(
                humaPoolFactoryContract
                    .connect(borrower)
                    .deployNewPool(testTokenContract.address, 100)
            ).to.be.revertedWith("HumaPoolFactory:CALLER_NOT_APPROVED");
        });
    });

    describe("HumaPool", function () {
        beforeEach(async function () {
            await testTokenContract.approve(
                humaPoolFactoryContract.address,
                99999
            );
            const tx = await humaPoolFactoryContract.deployNewPool(
                testTokenContract.address,
                100
            );
            const receipt = await tx.wait();
            let poolAddress;
            // eslint-disable-next-line no-restricted-syntax
            for (const evt of receipt.events) {
                if (evt.event === "PoolDeployed") {
                    poolAddress = evt.args[0];
                }
            }

            humaPoolContract = await ethers.getContractAt(
                "HumaPool",
                poolAddress,
                owner
            );

            await humaPoolContract.setInterestRateBasis(1200); //bps
            await humaPoolContract.setMaxLoanAmount(100);
            await humaPoolContract.enablePool();
            await humaPoolContract.setFees(10, 0, 0, 0, 0, 0);

            await testTokenContract.give1000To(lender.address);
            await testTokenContract
                .connect(lender)
                .approve(humaPoolContract.address, 99999);
        });

        it("Pool loan helper can only be approved by master admin", async function () {
            await humaPoolContract.setHumaPoolLoanHelper(
                "0x0000000000000000000000000000000000000001"
            );

            // Cannot deposit while helper not approved
            await expect(
                humaPoolContract.connect(lender).deposit(100)
            ).to.be.revertedWith("HumaPool:POOL_LOAN_HELPER_NOT_APPROVED");

            // Pool cannot be approved by non-master admin
            await expect(
                humaPoolContract
                    .connect(lender)
                    .setHumaPoolLoanHelperApprovalStatus(true)
            ).to.be.revertedWith("HumaPool:PERMISSION_DENIED_NOT_MASTER_ADMIN");

            // Approval by master admin should work
            await humaPoolContract.setHumaPoolLoanHelperApprovalStatus(true);

            // Deposit should work
            await humaPoolContract.connect(lender).deposit(100);
        });

        it("Only pool owner and master admin can edit pool settings", async function () {
            // Transfer ownership of pool to other account
            await humaPoolContract.transferOwnership(lender.address);

            // Master admin should succeed
            await humaPoolContract.setHumaPoolLoanHelper(
                "0x0000000000000000000000000000000000000000"
            );

            // Owner should succeed
            await humaPoolContract
                .connect(lender)
                .setHumaPoolLoanHelper(
                    "0x0000000000000000000000000000000000000000"
                );

            // Non-owner should fail
            await expect(
                humaPoolContract
                    .connect(borrower)
                    .setHumaPoolLoanHelper(
                        "0x0000000000000000000000000000000000000000"
                    )
            ).to.be.revertedWith("HumaPool:PERMISSION_DENIED_NOT_ADMIN");
        });

        // describe("Huma Pool Settings", function () {
        //   it("Set pool fees and parameters", async function () {
        //     var [maxLoanAmount, interest, f1, f2, f3, f4, f5, f6] = await humaPoolContract.getPoolSettings();
        //     expect(maxLoanAmount).to.equal(100);
        //     expect(interest).to.equal(1200);
        //     expect(f1).to.equal(10);
        //     expect(f2).to.equal(0);
        //     expect(f3).to.equal(20);
        //     expect(f4).to.equal(0);
        //     expect(f5).to.equal(30);
        //     expect(f6).to.equal(0);
        //   });
        // });

        describe("Depositing and withdrawal", function () {
            it("Cannot deposit while pool is off", async function () {
                await humaPoolContract.disablePool();
                await expect(
                    humaPoolContract.connect(lender).deposit(100)
                ).to.be.revertedWith("HumaPool:POOL_NOT_ON");
            });

            it("Pool deposit works correctly", async function () {
                await humaPoolContract.connect(lender).deposit(100);
                const lenderInfo = await humaPoolContract
                    .connect(lender)
                    .getLenderInfo(lender.address);
                expect(lenderInfo.amount).to.equal(100);
                expect(lenderInfo.mostRecentLoanTimestamp).to.not.equal(0);
                expect(await humaPoolContract.getPoolLiquidity()).to.equal(100);
            });

            it("Pool withdrawal works correctly", async function () {
                await humaPoolContract.connect(lender).deposit(100);

                // Test withdrawing before the lockout passes
                await expect(
                    humaPoolContract.connect(lender).withdraw(100)
                ).to.be.revertedWith("HumaPool:WITHDRAW_TOO_SOON");

                // Increment block by lockout period
                const loanWithdrawalLockout =
                    await humaPoolContract.getLoanWithdrawalLockoutPeriod();
                await ethers.provider.send("evm_increaseTime", [
                    loanWithdrawalLockout.toNumber(),
                ]);

                // Test withdrawing more than deposited fails
                await expect(
                    humaPoolContract.connect(lender).withdraw(9999)
                ).to.be.revertedWith("HumaPool:WITHDRAW_AMT_TOO_GREAT");

                // Test success case
                await humaPoolContract.connect(lender).withdraw(100);

                const lenderInfo = await humaPoolContract
                    .connect(lender)
                    .getLenderInfo(lender.address);
                expect(lenderInfo.amount).to.equal(0);
            });
        });

        describe("Borrowing and payback", function () {
            beforeEach(async function () {
                await humaPoolContract.connect(lender).deposit(101);
                await testTokenContract
                    .connect(borrower)
                    .approve(humaPoolContract.address, 99999);
            });

            it("Cannot request loan while pool is off", async function () {
                await humaPoolContract.disablePool();
                await expect(
                    humaPoolContract.connect(borrower).requestLoan(100, 30, 12)
                ).to.be.revertedWith("HumaPool:POOL_NOT_ON");
            });

            it("Cannot request loan greater than limit", async function () {
                await expect(
                    humaPoolContract.connect(borrower).requestLoan(9999, 30, 12)
                ).to.be.revertedWith("HumaPool:DENY_BORROW_GREATER_THAN_LIMIT");
            });

            it("Loan initiates correctly", async function () {
                expect(
                    await testTokenContract.balanceOf(borrower.address)
                ).to.equal(0);
                await humaPoolContract
                    .connect(owner)
                    .setInterestRateBasis(1200);
                await testTokenContract
                    .connect(borrower)
                    .approve(humaPoolContract.address, 0);

                await expect(
                    humaPoolContract.connect(borrower).requestLoan(10, 1000, 10)
                ).to.be.revertedWith("HumaPool:DENY_NO_ALLOWANCE");

                await testTokenContract
                    .connect(borrower)
                    .approve(humaPoolContract.address, 999999);

                await humaPoolContract
                    .connect(borrower)
                    .requestLoan(10, 1000, 10);

                const loanAddress = await humaPoolContract.creditMapping(
                    borrower.address
                );
                const loanContract = await getLoanContractFromAddress(
                    loanAddress,
                    borrower
                );
                const loanInformation = await loanContract.getLoanInformation();
                expect(loanInformation._id).to.equal(1);
                expect(loanInformation._amount).to.equal(10);
                expect(loanInformation._paybackInterval).to.equal(1000);
                expect(loanInformation._interestRateBasis).to.equal(1200);

                // expect(
                //     await testTokenContract.balanceOf(borrower.address)
                // ).to.equal(10);

                // expect(await humaPoolContract.getPoolLiquidity()).to.equal(90);

                // Borrowing with existing loans should fail
                await expect(
                    humaPoolContract.connect(borrower).requestLoan(10, 1000, 10)
                ).to.be.revertedWith("HumaPool:DENY_BORROW_EXISTING_LOAN");

                await testTokenContract
                    .connect(borrower2)
                    .approve(humaPoolContract.address, 10);
                // Test that id increments
                await humaPoolContract
                    .connect(borrower2)
                    .requestLoan(10, 1000, 10);
                const loanAddress2 = await humaPoolContract.walletToActiveLoan(
                    borrower2.address
                );
                const loanContract2 = await getLoanContractFromAddress(
                    loanAddress2,
                    borrower2
                );
                const loanInformation2 =
                    await loanContract2.getLoanInformation();
                expect(loanInformation2._id).to.equal(2);
            });

            describe("Loan Funding", function () {
                beforeEach(async function () {
                    await humaPoolContract
                        .connect(borrower)
                        .requestLoan(100, 30, 12);
                });

                // it("Prevent loan funding before approval", async function () {
                //   expect(await humaPoolContract.connect(borrower).originateLoan()).to.be.revertedWith("HumaPool:LOAN_NOT_APPROVED");
                // });

                it("Funding", async function () {
                    const loanAddress = await humaPoolContract.creditMapping(
                        borrower.address
                    );
                    const loanContract = await getLoanContractFromAddress(
                        loanAddress,
                        borrower
                    );
                    await loanContract.approve();
                    // expect(await loanContract.isApproved()).to.equal(true);

                    await humaPoolContract.connect(borrower).originateLoan();

                    // const loanInformation = await loanContract.getLoanInformation();
                    // console.log("amount", loanInformation._amount);
                    // console.log("amount per payback", loanInformation._paybackPerInterval);
                    // console.log("payback interval", loanInformation._paybackInterval);
                    // console.log("interest rate", loanInformation._interestRateBasis);
                    // console.log("Next due date", loanInformation._nextDueDate);
                    // console.log("principal paid back", loanInformation._principalPaidBack);
                    // console.log("remaining payments", loanInformation._remainingPayments);
                    // console.log("number of payments", loanInformation._numOfPayments);

                    expect(
                        await testTokenContract.balanceOf(borrower.address)
                    ).to.equal(90);

                    // Check the amount in the treasury.
                    // todo this does not work, not sure if it is test error or contract error.
                    // expect(await testTokenContract.balanceOf(owner.address)).to.equal(
                    //   10
                    // );

                    expect(await humaPoolContract.getPoolLiquidity()).to.equal(
                        1
                    );
                });
            });

            // describe("Payback", function () {
            //   beforeEach(async function () {
            //     await humaPoolContract.connect(borrower).requestLoan(100, 30, 12);

            //     loanAddress = await humaPoolContract.creditMapping(
            //       borrower.address
            //     );
            //     loanContract = await getLoanContractFromAddress(
            //       loanAddress,
            //       borrower
            //     );
            //     await loanContract.approve();
            //     await humaPoolContract.connect(borrower).originateLoan();
            //   });

            //   it("Process payback", async function () {
            //     await ethers.provider.send("evm_increaseTime", [30 * 24 * 3600]);
            //     const loanInformation = await loanContract.getLoanInformation();
            //     console.log(loanInformation._paybackPerInterval);
            //     console.log(loanInformation._amount);
            //     console.log(await testTokenContract.balanceOf(borrower.address));

            //     // todo the test complains not enough balance in the test account. Not sure
            //     // if it is a bug in the test or the contract.
            //     // await loanContract
            //     //   .connect(borrower)
            //     //   .makePayment(testTokenContract.address, 20);
            //     // console.log(9);

            //     // loanInformation = await loanContract.getLoanInformation();
            //     // expect(loanInformation._amountPaidBack).to.equal(20);
            //   });
            // });
        });
    });
});
