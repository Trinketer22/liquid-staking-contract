import '@ton/test-utils';
import { Blockchain, BlockchainSnapshot, createShardAccount, internal, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { Address, beginCell, Cell, Dictionary, toNano  } from '@ton/core';
import { Pool } from '../wrappers/Pool';
import { ConfigTest } from '../wrappers/ConfigTest';
import { compile } from '@ton/blueprint';
import { Controller } from '../wrappers/Controller';
import { Conf, Op } from '../PoolConstants';
import { ElectorTest } from '../wrappers/ElectorTest';
import { parseValidatorsSet, getElectionsConf, getVset, getStakeConf, getValidatorsConf } from '../wrappers/ValidatorUtils';
import {writeFile} from 'fs/promises';
import { getRandomInt } from '../utils';
import { getSecureRandomBytes, keyPairFromSeed } from 'ton-crypto';


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

let fetchStates: (accounts: Address[], opts: Partial<{ retryCount: number, key: string}>) => Promise<void>;
let fetchLibrary :(libHash: Buffer, retryCount?: number) => Promise<void>;
let libraries: Dictionary<Buffer,Cell>;
let getCurTime: () => number;
let printMsg: (...data: any[]) => void;
let mockRound:(profit: bigint) => Promise<void>;
let announceElections:() => Promise<number>;

const verbose = false;
const saveStates = false;
const apiKey: string | undefined = process.env.API_KEY;

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

        fetchStates = async (accounts, opts) => {
            const url = 'https://toncenter.com/api/v3/accountStates?';
            const key = opts.key;
            let retryCount = opts.retryCount ?? 5;

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
                            if(saveStates) {
                                await writeFile(`states/${accAddress}.state`, JSON.stringify(acc));
                            }
                            printMsg(`Account ${accAddress} loaded!`);
                        } else {
                            printMsg(`Account ${acc.address} is not active!`)
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
                    printMsg(`Library ${libHash.toString('base64')} loaded successfully`);
                    return;
                } catch (error) {
                    if(--retryCount < 0) {
                        throw new Error(`Failed to fetch library ${libHash.toString('base64')}`);
                    }

                    await sleep();
                }
            } while(true);
        }
        announceElections = async () => {
            const confDict = await config.getConfigDict();
            const electConf = getElectionsConf(confDict);
            const electAt = await elector.getActiveElectionId();
            const curTime = getCurTime();
            const curVset = getVset(blockchain.config, 34);
            // printMsg("Elect conf:", electConf);
            const electBegin = curVset.utime_unitl - electConf.begin_before;
            const electEnd   = curVset.utime_unitl - electConf.end_before;
            const nextVset = confDict.get(36);
            if(curTime > electEnd) {
                printMsg(`Elections already ended`);
            }
            if(electAt >= electBegin && curTime < electEnd) {
                printMsg("Elections anounced already!");
                printMsg(`End at: ${electAt}, began at ${electBegin}`);
                printMsg(`Delta ${curTime - electBegin}`);
                return electAt;
            } else if(!nextVset) {
                printMsg("Next vset is not present")
                blockchain.now = (curTime < electBegin ? electBegin : electAt) + 1;
                await elector.sendTickTock("tick");
                await elector.sendTickTock("tock");
            } else {
                printMsg("Elections not annouced yet!");

                if(curVset.type !== 'ext') {
                    throw new Error("No way");
                }
                printMsg(`Cur time:${curTime}`);
                printMsg(`Vset till: ${curVset.utime_unitl}`);
                if(curTime < curVset.utime_unitl) {
                    // expect(nextVset).not.toBeUndefined();
                    const nextVsetParsed = parseValidatorsSet(nextVset.beginParse());
                    printMsg("Updating next vset");
                    if(nextVsetParsed.type !== 'ext') {
                        throw new Error("ext new vset expected!")
                    }
                    blockchain.now = nextVsetParsed.utime_since;
                    await config.sendTickTock('tick');
                    await config.sendTickTock('tock');
                    const newConfig = await config.getConfigDict();
                    expect(newConfig.get(36)).toBeUndefined();
                    blockchain.setConfig(await config.getConfigCell())
                    blockchain.now = nextVsetParsed.utime_unitl - electConf.begin_before + 1;
                }
            }
            await elector.sendTickTock("tick");
            await elector.sendTickTock("tock");

            const newElections = await elector.getActiveElectionId();
            expect(newElections).not.toBe(0);
            return newElections;
        }
        mockRound = async(profit) => {
            const confDict = await config.getConfigDict();
            const vConf = getValidatorsConf(confDict);
            const stakeConf = getStakeConf(confDict);
            const electConf = getElectionsConf(confDict);
            const elect = await elector.getElections();
            const participants = elect.members;
            let totalStake = elect.totalStake;
            let totalParticipants = participants.size;
            printMsg("Initial participants:", totalParticipants)
            let mockValidators = await blockchain.createWallets(100, {workchain: -1, balance: toNano('10000000')});
            const roundIdx = await elector.getActiveElectionId();
            let vdIdx = 0;

            await blockchain.sendMessage(internal({
                from: new Address(-1, Buffer.alloc(32, 0)),
                to: elector.address,
                value: profit,
                bounce: false
            }));

            while(totalParticipants < vConf.min_validators || totalStake < stakeConf.min_total_stake) {
                const keyPair = keyPairFromSeed(await getSecureRandomBytes(32))
                const curValidator = mockValidators[vdIdx++];
                const stakeSize = toNano('1000000');
                const res = await elector.sendNewStake(curValidator.getSender(), stakeSize, curValidator.address, keyPair.publicKey, keyPair.secretKey, roundIdx);
                // printMsg(`Validator ${vdIdx} is staking...`);

                expect(res.transactions).toHaveTransaction({
                    on: curValidator.address,
                    from: elector.address,
                    op: Op.elector.new_stake_ok
                });
                const electAfter = await elector.getElections();

                // printMsg("Ok");
                totalStake = electAfter.totalStake;
                totalParticipants++;
            }
            // Set time to elect_at
            blockchain.now = roundIdx;
            const vsetUpd = await elector.sendTickTock("tick");
            expect(vsetUpd.transactions).toHaveTransaction({
                on: config.address,
                from: elector.address,
                aborted: false
            });
            blockchain.setConfig(await config.getConfigCell());
            const nextVset = getVset(blockchain.config, 36);

            if(getCurTime() < nextVset.utime_since) {
                printMsg("Updating vset time")
                blockchain.now = nextVset.utime_since;
            }

            await config.sendTickTock("tock");
            const configAfter = await config.getConfigCell();
            expect(blockchain.config).not.toEqualCell(configAfter);
            await elector.sendTickTock("tick");
            await elector.sendTickTock("tock");
            blockchain.setConfig(configAfter);
        }
        getCurTime = () => {
            return blockchain.now ?? Math.floor(Date.now() / 1000);
        }
        printMsg = (...msg) => {
            if(verbose) {
                console.log(...msg);
            }
        }

        await fetchStates([poolAddress, configAddress, electorAddress], {key: apiKey});

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


        await fetchStates(accountsToFetch, {key: apiKey});
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

        const curElections = await announceElections();
        printMsg(`Elections close round:${curElections}`);
        let prevRoundCurrentlyValidating = false;
        let waitUnfreeze = false;
        for(let borrower of prevRoundBorrowers) {
            const controllerData = await borrower.getControllerData();
            const validatorSender = blockchain.sender(controllerData.validator);
            // console.log("Change count:", controllerData.validatorSetChangeCount);

            if(controllerData.validatorSetChangeCount < 2) {
                await borrower.sendUpdateHash(validatorSender);
                const afterUpdate = await borrower.getControllerData();
                if(afterUpdate.validatorSetChangeCount == controllerData.validatorSetChangeCount) {
                    prevRoundCurrentlyValidating = true;
                }
            }
        }
        if(prevRoundCurrentlyValidating) {
            printMsg(`Prev round borrowers are currently validating`);
            await mockRound(toNano('10000'));
            // Announce next elections
            const nextElections = await announceElections();
            expect(nextElections).toBeGreaterThan(curElections);
            blockchain.setConfig(await config.getConfigCell());
            // borrowTime = blockchain.snapshot();
        }
        let lastSetChanged = 0;
        for(const borrower of prevRoundBorrowers) {
            const curData = await borrower.getControllerData();
            const validatorSender = blockchain.sender(curData.validator);
            await borrower.sendUpdateHash(validatorSender);
            const dataAfter = await borrower.getControllerData();
            lastSetChanged = Math.max(lastSetChanged, dataAfter.validatorSetChangeTime);
            // console.log("Last state changed:", lastSetChanged);
        }

        const unfreezeAt = lastSetChanged + electConf.stake_held_for + 61;
        const curVset  = getVset(blockchain.config, 34);
        if(curVset.utime_unitl < unfreezeAt) {
            printMsg("Go next round");
            await mockRound(toNano('10000'));
        } else if(getCurTime() < unfreezeAt) {
            printMsg("Wait unfreeze")
            waitUnfreeze = true;
            blockchain.now = unfreezeAt;
            await elector.sendTickTock('tick');
            await elector.sendTickTock('tock');
            await config.sendTickTock('tock');
        }

        for(let borrower of prevRoundBorrowers) {
            const curData = await borrower.getControllerData();
            const validatorSender = blockchain.sender(curData.validator);

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

        blockchain.setConfig(await config.getConfigCell());
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
        // blockchain.setConfig(await config.getConfigCell());
        await pool.sendTouch(testWalelt.getSender());
        const poolData = await pool.getFullData();
        // Pick random 10 new controller to borrow
        const randomIndexes: Set<number> = new Set();
        const confDict = await config.getConfigDict();

        const curElections = await announceElections();
        printMsg(`New borrow elections: ${curElections}`)
        blockchain.setConfig(await config.getConfigCell());
        //console.log(`Cur time:`, getCurTime())
        // Self test
        expect(getVset(blockchain.config, 34)).toEqual(getVset(await config.getConfigDict(), 34));
        //console.log(`Cur vset:`, getVset(blockchain.config, 34));
        //console.log(`Cur vset config:`, getVset(await config.getConfigDict(), 34));


        let i = 0;
        const electConf = getElectionsConf(confDict);
        const curVset = getVset(confDict, 34);
        const curTime = getCurTime();
        printMsg(`End of elections: ${curVset.utime_unitl - electConf.end_before - curTime} cur time ${curTime}`)
        if(curTime < curVset.utime_unitl - electConf.begin_before) {
            throw new Error("Not started yet")
        }

        do {
            const newIdx = getRandomInt(0, newControllers.length - 1);
            if(!randomIndexes.has(newIdx)) {
                randomIndexes.add(newIdx);
                printMsg(`Borrowing ${i++}`);
                const testController = newControllers[newIdx];
                const controllerData = await testController.getControllerData();

                const validatorSender = blockchain.sender(controllerData.validator);
                await testController.sendUpdateHash(validatorSender);
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
