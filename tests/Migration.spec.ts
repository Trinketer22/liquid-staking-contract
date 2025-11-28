import '@ton/test-utils';
import { Blockchain, createShardAccount, SandboxContract } from '@ton/sandbox';
import { Address, beginCell, Cell, Dictionary  } from '@ton/core';
import { Pool } from '../wrappers/Pool';
import { ConfigTest } from '../wrappers/ConfigTest';
import { compile } from '@ton/blueprint';
import { Controller } from '../wrappers/Controller';
import { Op } from '../PoolConstants';


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

let currentRoundBorrowers: SandboxContract<Controller>[];
let prevRoundBorrowers: SandboxContract<Controller>[];

let newPoolCode: Cell;
let newControllerCode: Cell;

let fetchStates: (accounts: Address[], retryCount?: number, key?: string) => Promise<void>;
let fetchLibrary :(libHash: Buffer, retryCount?: number) => Promise<void>;
let libraries: Dictionary<Buffer,Cell>;

describe('Pool migration test', () => {
    beforeAll(async () => {
        blockchain = await Blockchain.create();
        libraries = Dictionary.empty(Dictionary.Keys.Buffer(32), Dictionary.Values.Cell());
        const poolAddress = Address.parse("EQCkWxfyhAkim3g2DjKQQg8T5P4g-Q1-K_jErGcDJZ4i-vqR");
        const configAddress = Address.parse("Ef9VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVbxn");

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

        await fetchStates([poolAddress, configAddress]);

        pool = blockchain.openContract(Pool.createFromAddress(poolAddress));
        config = blockchain.openContract(ConfigTest.createFromAddress(configAddress))

        blockchain.libs = beginCell().storeDictDirect(libraries).endCell();
        blockchain.setConfig(await config.getConfigCell());

        console.log("Before dicts");
        const curBorrowersDict = await pool.getBorrowersDict(false);
        const prevBorrowersDict = await pool.getBorrowersDict(true);

        const poolData = await pool.getFullData();
        console.log("After dicts");
        let accountsToFetch: Address[] = [];
        if(poolData.depositPayout) {
            accountsToFetch.push(poolData.depositPayout);
        }
        if(poolData.withdrawalPayout) {
            accountsToFetch.push(poolData.withdrawalPayout);
        }


        const parseBorrower = (k: bigint) => {
            console.log(k.toString(16))
            const vaidatorAddress = new Address(-1, Buffer.from(k.toString(16).padStart(64, '0'), 'hex'));
            accountsToFetch.push(vaidatorAddress);
        }


        [...curBorrowersDict.keys(),
        ...prevBorrowersDict.keys()].forEach(parseBorrower)

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
    });
})
