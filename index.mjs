import * as path from 'node:path';
import * as url from 'node:url';
import * as core from '@actions/core';
import * as exec from '@actions/exec';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));

const setupPs1 = path.resolve(__dirname, '../setup.ps1');
const cleanupPs1 = path.resolve(__dirname, '../cleanup.ps1');

const isPost = core.getState('IsPost');
core.saveState('IsPost', true);

const connectionStringName = core.getInput('connection-string-name', { required: true });
const imageTag = core.getInput('image-tag') || '9.4.5.1-r1';
const initScript = core.getInput('init-script');

async function run() {
    try {
        if (!isPost) {
            console.log('Running setup action');

            const containerName = 'ibmmq';
            core.saveState('ContainerName', containerName);

            console.log(`containerName = ${containerName}`);
            console.log(`imageTag = ${imageTag}`);

            await exec.exec('pwsh', [
                '-File', setupPs1,
                '-ContainerName', containerName,
                '-ConnectionStringName', connectionStringName,
                '-ImageTag', imageTag,
                '-InitScript', initScript
            ]);
        } else {
            console.log('Running cleanup');

            const containerName = core.getState('ContainerName');

            await exec.exec('pwsh', [
                '-File', cleanupPs1,
                '-ContainerName', containerName
            ]);
        }
    } catch (err) {
        core.setFailed(err);
        console.log(err);
    }
}

run();