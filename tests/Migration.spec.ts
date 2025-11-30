import '@ton/test-utils';
import { Blockchain, createShardAccount, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { Address, beginCell, Cell, Dictionary, toNano  } from '@ton/core';
import { Pool } from '../wrappers/Pool';
import { ConfigTest } from '../wrappers/ConfigTest';
import { compile } from '@ton/blueprint';
import { Controller } from '../wrappers/Controller';
import { Conf, ControllerState, Op } from '../PoolConstants';
import { ElectorTest } from '../wrappers/ElectorTest';
import { parseValidatorsSet, getElectionsConf, getVset } from '../wrappers/ValidatorUtils';
import {writeFile} from 'fs/promises';
import { getRandomInt } from '../utils';


type AccountState = {
    address: string,
    status: string,
    balance: string,
    code_boc: string,
    data_boc: string,
    last_transaction_lt: string
};

const sleep = async (ms: number = 3000) => {
    return new Promise( (resolve, reject)=>
        setTimeout(resolve, ms)
    );
}

let blockchain: Blockchain;
let config: SandboxContract<ConfigTest>;
let pool: SandboxContract<Pool>;
let elector: SandboxContract<ElectorTest>;
let testWalelt: SandboxContract<TreasuryContract>;

let currentRoundBorrowers: SandboxContract<Controller>[];
let prevRoundBorrowers: SandboxContract<Controller>[];

let newControllers: SandboxContract<Controller>[];

let newPoolCode: Cell;
let newControllerCode: Cell;

let fetchStates: (accounts: Address[], retryCount?: number, key?: string) => Promise<void>;
let fetchLibrary :(libHash: Buffer, retryCount?: number) => Promise<void>;
let libraries: Dictionary<Buffer,Cell>;

describe('Pool migration test', () => {
    beforeAll(async () => {
        blockchain = await Blockchain.create();
        blockchain.now = Math.floor(Date.now() / 1000);
        testWalelt = await blockchain.treasury('test_wallet');
        libraries = Dictionary.empty(Dictionary.Keys.Buffer(32), Dictionary.Values.Cell());
        const poolAddress = Address.parse("EQCkWxfyhAkim3g2DjKQQg8T5P4g-Q1-K_jErGcDJZ4i-vqR");
        const configAddress = Address.parse("Ef9VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVbxn");
        const electorAddress = Address.parse("Ef8zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM0vF");

        newPoolCode = await compile('Pool');
        newControllerCode = await compile('Controller');

        currentRoundBorrowers = [];
        prevRoundBorrowers = [];

        fetchStates = async (accounts, retryCount = 5, key?: string) => {
            const url = 'https://toncenter.com/api/v3/accountStates?';

            do {
                try {
                    const params = new URLSearchParams({
                        include_boc: 'true'
                    });

                    const headers = new Headers({
                        'accept': 'application/json'
                    });

                    if(key) {
                        headers.append('X-API-Key', key);
                    }

                    const loadLibsFromCell = async (data: Cell) => {
                        if(data.isExotic) {
                            const ds = data.beginParse(true);
                            const type = ds.loadUint(8);
                            if(type == 2) {
                                const libHash = ds.loadBuffer(32);
                                if(!libraries.has(libHash)) {
                                    await fetchLibrary(libHash, retryCount);
                                }
                                return;
                            }
                        }
                        for(let childCell of data.refs) {
                            await loadLibsFromCell(childCell);
                        }
                    }

                    accounts.forEach(acc => {
                        params.append('address', acc.toRawString())
                    });

                    const reqUrl = url + params;

                    const res = await fetch(reqUrl, {
                        headers
                    });

                    if(!res.ok) {
                        throw new Error(`Responed with ${res.status}`)
                    }

                    const accRes = (await res.json()).accounts as AccountState[];
                    for(let acc of accRes){
                        if(acc.status == 'active') {
                            const accAddress = Address.parse(acc.address);

                            const codeCell = Cell.fromBase64(acc.code_boc);
                            await loadLibsFromCell(codeCell);

                            const dataCell= Cell.fromBase64(acc.data_boc);
                            await loadLibsFromCell(dataCell);

                            await blockchain.setShardAccount(accAddress, createShardAccount({
                                address: accAddress,
                                balance: BigInt(acc.balance),
                                code: codeCell,
                                data: dataCell
                            }))
                            await writeFile(`states/${accAddress}.state`, JSON.stringify(acc));
                            console.log(`Account ${accAddress} loaded!`);
                        } else {
                            console.log(`Account ${acc.address} is not active!`)
                        }
                    }

                    return;
                } catch(e) {
                    console.error(e);
                    if(--retryCount < 0) {
                        throw new Error("Failed to fetch accounts!");
                    }
                    await sleep();
                }
            } while(true);
        }
        fetchLibrary = async (libHash: Buffer, retryCount: number = 5) => {
            const params = new URLSearchParams({
                libraries: libHash.toString('base64')
            })
            let dataCell: Cell | undefined;

            const url = 'https://toncenter.com/api/v2/getLibraries?' + params;
            const headers = { 'Accept': 'application/json' };

            do{
                try {
                    const response = await fetch(url, { headers });
                    const resp = await response.json();
                    dataCell = Cell.fromBase64(resp.result.result[0].data);
                    libraries.set(libHash, dataCell);
                    console.log(`Library ${libHash.toString('base64')} loaded successfully`);
                    return;
                } catch (error) {
                    if(--retryCount < 0) {
                        throw new Error(`Failed to fetch library ${libHash.toString('base64')}`);
                    }

                    await sleep();
                }
            } while(true);
        }

        await fetchStates([poolAddress, configAddress, electorAddress]);

        pool = blockchain.openContract(Pool.createFromAddress(poolAddress));
        config = blockchain.openContract(ConfigTest.createFromAddress(configAddress))
        elector = blockchain.openContract(ElectorTest.createFromAddress(electorAddress));

        blockchain.libs = beginCell().storeDictDirect(libraries).endCell();
        blockchain.setConfig(await config.getConfigCell());

        const curBorrowersDict = await pool.getBorrowersDict(false);
        const prevBorrowersDict = await pool.getBorrowersDict(true);

        const poolData = await pool.getFullData();
        let accountsToFetch: Address[] = [];
        if(poolData.depositPayout) {
            accountsToFetch.push(poolData.depositPayout);
        }
        if(poolData.withdrawalPayout) {
            accountsToFetch.push(poolData.withdrawalPayout);
        }


        const parseBorrower = (k: bigint) => {
            const controllerAddress = new Address(-1, Buffer.from(k.toString(16).padStart(64, '0'), 'hex'));
            accountsToFetch.push(controllerAddress);
            return controllerAddress;
        }

        [...curBorrowersDict.keys()].forEach(k => {
            const controllerAddress = parseBorrower(k);
            currentRoundBorrowers.push(blockchain.openContract(Controller.createFromAddress(controllerAddress)))
        });
        [...prevBorrowersDict.keys()].forEach(k => {
            const controllerAddress = parseBorrower(k);
            prevRoundBorrowers.push(blockchain.openContract(Controller.createFromAddress(controllerAddress)))
        });


        await fetchStates(accountsToFetch);
    })

    it('should be able to set current code', async () => {
        const poolData = await pool.getFullData();
        expect(poolData.contract_version).toBe(1);

        const sudoerSender = blockchain.sender(poolData.sudoer);

        const res = await pool.sendUpgrade(sudoerSender,null, newPoolCode, null);
        expect(res.transactions).toHaveTransaction({
            on: pool.address,
            op: Op.sudo.upgrade,
            aborted: false
        })
        const poolAfter = await pool.getFullData();
        expect(poolAfter.contract_version).toBe(3);
        expect(poolAfter.currentRound.withdrawRatePrev2X24).toBe(0n);
        expect(poolAfter.previousRound.withdrawRatePrev2X24).toBe(0n);
    });

    it('should be able to set controller code', async () => {
        const poolData = await pool.getFullData();
        expect(poolData.controllerCode).not.toEqualCell(newControllerCode);
        const sudoerSender = blockchain.sender(poolData.sudoer);
        await pool.sendSetCodes(sudoerSender, {
            controller: newControllerCode
        });

        const poolAfter = await pool.getFullData();
        expect(poolAfter.controllerCode).toEqualCell(newControllerCode);
    })
    it('should be able to close previous round', async () => {
        const confDict = await config.getConfigDict();
        const electConf = getElectionsConf(confDict);
        const electionsAnnounced = await elector.getActiveElectionId();
        if(electionsAnnounced) {
            console.log("Elections anounced already!");
        } else {
            console.log("Elections not annouced yet!");
            const curVset = getVset(confDict, 34);

            if(curVset.type !== 'ext') {
                throw new Error("No way");
            }
            console.log("Cur time:", blockchain.now);
            console.log("Vset till:", curVset.utime_unitl);
            if(blockchain.now! < curVset.utime_unitl) {
                const nextVset = confDict.get(36);
                // expect(nextVset).not.toBeUndefined();
                if(nextVset) {
                    const nextVsetParsed = parseValidatorsSet(nextVset.beginParse());
                    if(nextVsetParsed.type !== 'ext') {
                        throw new Error("ext new vset expected!")
                    }
                    blockchain.now = nextVsetParsed.utime_since;
                    await config.sendTickTock('tick');
                    await config.sendTickTock('tock');
                    const newConfig = await config.getConfigDict();
                    expect(newConfig.get(36)).toBeUndefined();
                } else {
                    const nextElectTime = curVset.utime_unitl - electConf.begin_before
                    if(blockchain.now! < nextElectTime) {
                        blockchain.now = nextElectTime + 1;
                    } else {
                        console.log("Elections can be started at this point")
                    }
                }
            }

            await elector.sendTickTock("tick");
            await elector.sendTickTock("tock");

            const newElections = await elector.getActiveElectionId();
            expect(newElections).not.toBe(0);
            console.log("Elections announced!");
        }
        for(let borrower of prevRoundBorrowers) {
            const controllerData = await borrower.getControllerData();
            const validatorSender = blockchain.sender(controllerData.validator);
            let changeTime = controllerData.validatorSetChangeTime;

            if(controllerData.validatorSetChangeCount < 2) {
                const res = await borrower.sendUpdateHash(validatorSender);
                changeTime = res.transactions[0].now;
            }

            const unfreezeAt = changeTime + electConf.stake_held_for + 61;
            if(blockchain.now! < unfreezeAt) {
                blockchain.now = unfreezeAt;
                await elector.sendTickTock('tick');
                await elector.sendTickTock('tock');
            }

            const dataAfter = await borrower.getControllerData();

            const withdrawRes = await borrower.sendRecoverStake(validatorSender);

            expect(withdrawRes.transactions).toHaveTransaction({
                from: elector.address,
                to: borrower.address,
                op: Op.elector.recover_stake_ok,
                aborted: false
            });
            expect(withdrawRes.transactions).toHaveTransaction({
                on: pool.address,
                from: borrower.address,
                op: Op.pool.loan_repayment,
                aborted: false
            })
        }
        const poolAfter = await pool.getFullData();
        // Round rotated
        expect(poolAfter.currentRound.borrowed).toBe(0n);
        expect(poolAfter.currentRound.withdrawRatePrev2X24).toBeGreaterThan(0);
    });
    it('should be able to deploy new controllers for all the borrowers', async () => {
        newControllers = [];

        for(let borrower of [...currentRoundBorrowers,...prevRoundBorrowers]) {
            const controllerData = await borrower.getControllerData();
            const validatorSender = blockchain.sender(controllerData.validator);
            const controllerId = await borrower.getControllerId();
            const expectedController = await pool.getControllerAddress(controllerId, controllerData.validator);

            const deployRes = await pool.sendRequestControllerDeploy(validatorSender, toNano('1000'), controllerId);

            expect(deployRes.transactions).toHaveTransaction({
                on: expectedController,
                from: pool.address,
                op: Op.controller.top_up,
                aborted: false,
                deploy: true
            });

            const newController = blockchain.openContract(Controller.createFromAddress(expectedController));
            newControllers.push(newController);
        }
    })
    it('should be able to approve new controllers', async () => {
        const poolData = await pool.getFullData();
        const approverSender = blockchain.sender(poolData.approver);
        for(let newController of newControllers) {
            const dataBefore = await newController.getControllerData();
            expect(dataBefore.approved).toBe(false);
            await newController.sendApprove(approverSender, true);
            expect((await newController.getControllerData()).approved).toBe(true);
        }
    })
    it('should be able to set revShare on pool', async () => {
        const poolData = await pool.getFullData();
        expect(poolData.revShare).toBe(0);
        const governorSender = blockchain.sender(poolData.governor);
        const revShare = Number(Conf.shareBase / 2n);
        await pool.sendSetDepositSettings(governorSender, toNano('1'), poolData.optimisticDepositWithdrawals, poolData.depositsOpen, poolData.instantWithdrawalFee, revShare);
        const poolAfter = await pool.getFullData();

        expect(poolAfter.revShare).toEqual(revShare);
        // Just in case
        expect(poolAfter.optimisticDepositWithdrawals).toEqual(poolData.optimisticDepositWithdrawals);
        expect(poolAfter.depositsOpen).toEqual(poolData.depositsOpen);
        expect(poolAfter.instantWithdrawalFee).toEqual(poolData.instantWithdrawalFee);
    })
    it('should be able to borrow with new controllers', async () => {
        const poolData = await pool.getFullData();
        // Pick random 10 new controller to borrow
        const randomIndexes: Set<number> = new Set();

        let i = 0;

        do {
            const newIdx = getRandomInt(0, newControllers.length - 1);
            if(!randomIndexes.has(newIdx)) {
                randomIndexes.add(newIdx);
                i++;
                const testController = newControllers[newIdx];
                const controllerData = await testController.getControllerData();
                const validatorSender = blockchain.sender(controllerData.validator);
                const res = await testController.sendRequestLoan(validatorSender, poolData.minLoan, poolData.minLoan * 2n, poolData.revShare, poolData.revShare);
                expect(res.transactions).toHaveTransaction({
                    on: testController.address,
                    from: pool.address,
                    op: Op.controller.credit,
                    aborted: false
                })
            }
        } while(i < 10);
    })
})
