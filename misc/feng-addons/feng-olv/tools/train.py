#!/usr/bin/env python3
"""Single OLV training entry. Frozen benchmark is evaluation-only, never selection.

python train.py --out F:/godot/feng-godot/Temp/olv-training --steps 100000
python train.py --evaluate-test --bundle ../model --out <new-results-directory>
python train.py --evaluate-benchmark --bundle ../model --out <new-results-directory>
"""
from pathlib import Path
import argparse,copy,hashlib,json,math,random,time
import numpy as np
import inference as core

HERE=Path(__file__).resolve().parent
DEFAULT_DATA=HERE.parent/'data'
DEFAULT_MODEL=HERE.parent/'model'

def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        while chunk:=f.read(8*1024*1024):h.update(chunk)
    return h.hexdigest()

def write(path,value):
    Path(path).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

def metrics(labels,probs):
    labels=np.asarray(labels,dtype='i8');pred=probs.argmax(1)+1
    confusion=np.zeros((2,2),dtype='i8');np.add.at(confusion,(labels-1,pred-1),1)
    f1=[]
    for i in range(2):
        tp=int(confusion[i,i]);den=int(confusion[i].sum()+confusion[:,i].sum())
        f1.append(2*tp/den if den else 0.)
    return dict(subjects=len(labels),accuracy=float(np.mean(pred==labels)),macro_f1=float(np.mean(f1)),
        cross_entropy=float(-np.log(np.maximum(probs[np.arange(len(labels)),labels-1],1e-12)).mean()),
        exterior_predicted_interior=int(confusion[0,1]),interior_predicted_exterior=int(confusion[1,0]),confusion_matrix=confusion.tolist())

def predict(torch,models,mean,std,features,device):
    return np.concatenate([core._predict_probs(torch,models,mean,std,features[i:i+512].copy(),device,None)
        for i in range(0,len(features),512)])

def evaluate(args):
    manifest,sha,(torch,mean,std),models=core._load_bundle(args.bundle)
    torch.set_num_threads(2)
    result=dict(model_bundle_sha256=sha,checkpoint=int(manifest.get('checkpoint_step',0)),training_performed=False)
    if args.evaluate_benchmark:
        folder=args.data/'benchmark'
        seal=json.loads((folder/'features_surface_patch_horizon16_v2.seal.json').read_text(encoding='utf-8'))
        features_path=folder/'features_surface_patch_horizon16_v2.npy'
        assert digest(features_path)==seal['sha256']
        assert digest(folder/'manifest.json')==seal['exam_manifest_sha256']
        with np.load(folder/'subjects.npz',allow_pickle=False) as z:
            labels=z['labels'];tiers=z['tiers'];groups=z['groups']
        probs=predict(torch,models,mean,std,np.load(features_path,mmap_mode='r'),args.device)
        result.update(usage='benchmark_only_never_training',overall=metrics(labels,probs),
            tiers={name:metrics(labels[tiers==i],probs[tiers==i]) for i,name in enumerate(('simple','medium','extreme'))},
            groups={str(i):metrics(labels[groups==i],probs[groups==i]) for i in np.unique(groups)})
    else:
        with np.load(args.data/'test.npz',allow_pickle=False) as z:
            result['suites']={}
            for suite in sorted({key.split('__')[0] for key in z.files}):
                labels=z[suite+'__labels'];scores=[]
                for view in ('r4','q90'):
                    scores.append(metrics(labels,predict(torch,models,mean,std,z[suite+'__'+view],args.device)))
                result['suites'][suite]=dict(primary=scores[0],q90=scores[1],views_are_correlated=True)
    write(args.out/'evaluation.json',result)
    print(json.dumps(result,ensure_ascii=False),flush=True)

def export_bundle(folder,state,normalizer,template,step,validation,seed):
    import torch
    folder.mkdir(parents=True,exist_ok=False)
    torch.save(state,folder/'model.pt');write(folder/'normalizer.json',normalizer)
    manifest=copy.deepcopy(template)
    manifest.update(candidate_id=f'olv-trained-step-{step}',candidate_status='development_selected',
        checkpoint_step=step,checkpoint_cumulative_updates=step,checkpoint_phase='train',
        initialization='random_from_seed',training_stage='fresh_supervised_pretraining',
        checkpoint_selection='maximum independent development Macro-F1; then minimum development cross entropy',
        inherited_weight_updates=0,model_input_transform='surface_origin_residual_v1',
        normalizer_sha256=digest(folder/'normalizer.json'),validation=validation,
        seeds=[dict(seed=seed,checkpoint_file='model.pt',checkpoint_sha256=digest(folder/'model.pt'))])
    write(folder/'inference_manifest.json',manifest)
    core._load_bundle(folder)

def train(args):
    torch=core.baseline__load_torch();torch.set_num_threads(2)
    random.seed(args.seed);np.random.seed(args.seed);torch.manual_seed(args.seed)
    device=core.baseline__resolve_device(torch,args.device)
    template=json.loads((DEFAULT_MODEL/'inference_manifest.json').read_text(encoding='utf-8'))
    with np.load(args.data/'train.npz',allow_pickle=False) as z:
        count=len(z['train_labels']) if args.limit is None else min(args.limit,len(z['train_labels']))
        all_labels=z['train_labels']
        indices=np.arange(count) if args.limit is None else np.concatenate([np.flatnonzero(all_labels==1)[:count//2],np.flatnonzero(all_labels==2)[:count-count//2]])
        labels=all_labels[indices].astype('i8')
        ids=z['train_candidate_ids'][indices]
        views=[z['train_r4'][indices],z['train_q90'][indices]]
    with np.load(args.data/'train_views.npz',allow_pickle=False) as z:
        assert np.array_equal(ids,z['ids'][indices])
        auxiliary=z['views'][indices]
        views.extend(auxiliary[:,i].copy() for i in range(4))
    assert set(np.unique(labels))=={1,2} and len(np.unique(ids))==count
    # Normalization uses TRAIN I/Q90 only, matching the deployed observation contract.
    sums=sum(v.sum(axis=(0,1),dtype='f8') for v in views[:2]);den=2*count*64
    mean=(sums/den).astype('f4')
    variance=sum(((v.astype('f8')-mean)**2).sum(axis=(0,1)) for v in views[:2])/den
    std=np.maximum(np.sqrt(variance),1e-6).astype('f4')
    normalizer=dict(mean=mean.tolist(),std=std.tolist(),fit_scope='TRAIN I/Q90 only')
    tensors=[torch.from_numpy(np.ascontiguousarray(v)).to(device) for v in views]
    del views,auxiliary
    y=torch.from_numpy(labels-1).to(device)
    mu=torch.as_tensor(mean,device=device).reshape(1,1,26);sigma=torch.as_tensor(std,device=device).reshape(1,1,26)
    model=core.baseline_new_model(torch,26,model_width=64,attention_heads=2,encoder_layers=3,
        feedforward_width=380,class_count=2,pooling='class_query').to(device)
    assert sum(p.numel() for p in model.parameters() if p.requires_grad)==200052
    core.configure_model_input_transform(torch,model,mean,std,'surface_origin_residual_v1')
    optimizer=torch.optim.AdamW(model.parameters(),lr=args.learning_rate,weight_decay=.01)
    validation=[]
    for name in ('validation.npz','hard_validation.npz'):
        with np.load(args.data/name,allow_pickle=False) as z:
            n=len(z['labels']) if args.limit is None else min(args.limit,len(z['labels']))
            assert not np.intersect1d(ids,z['ids'][:n]).size
            validation.extend([(z[v][:n].copy(),z['labels'][:n].copy()) for v in ('r4','q90')])
    protocol=dict(training_subjects=count,parameters=200052,steps=args.steps,seed=args.seed,
        initialization='random_from_seed',post_training_updates=0,benchmark_used_for_training=False,
        test_used_for_selection=False,source_dataset_manifest_sha256=digest(args.data/'manifest.json'),
        script_sha256=digest(__file__),model_selection='development only',args=vars(args)|{'data':str(args.data),'out':str(args.out),'bundle':str(args.bundle)})
    write(args.out/'protocol.json',protocol);best=None;best_state=None;history=[];started=time.perf_counter()
    for step in range(1,args.steps+1):
        model.train();optimizer.zero_grad(set_to_none=True)
        optimizer.param_groups[0]['lr']=args.learning_rate*(.1+.9*.5*(1+math.cos(math.pi*(step-1)/max(1,args.steps))))
        indices=torch.randint(count,(args.batch_size,),device=device)
        a=random.randrange(len(tensors));b=random.randrange(len(tensors))
        first=model((tensors[a][indices]-mu)/sigma)
        second=model((tensors[b][indices]-mu)/sigma)
        ce=(torch.nn.functional.cross_entropy(first,y[indices])+torch.nn.functional.cross_entropy(second,y[indices]))*.5
        consistency=(first.softmax(-1)-second.softmax(-1)).square().sum(-1).mean()
        loss=ce+.25*consistency
        loss.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),1.0);optimizer.step()
        if step%args.checkpoint_every and step!=args.steps:continue
        model.eval();probs=[];truth=[]
        with torch.inference_mode():
            for features,targets in validation:
                probs.append(predict(torch,[(args.seed,model)],mean,std,features,args.device));truth.append(targets)
        score=metrics(np.concatenate(truth),np.concatenate(probs));history.append(dict(step=step,**score))
        key=(score['macro_f1'],-score['cross_entropy'])
        if best is None or key>best:
            best=key;best_state={k:v.detach().cpu().clone() for k,v in model.state_dict().items()};selected=dict(step=step,validation=score)
        print(json.dumps(dict(step=step,loss=float(loss.detach()),validation=score)),flush=True)
    export_bundle(args.out/'model',best_state,normalizer,template,selected['step'],selected['validation'],args.seed)
    write(args.out/'training_result.json',dict(status='complete',selected=selected,history=history,elapsed_seconds=time.perf_counter()-started,
        test_or_benchmark_read=False,production_model_overwritten=False))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--data',type=Path,default=DEFAULT_DATA);p.add_argument('--bundle',type=Path,default=DEFAULT_MODEL)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--steps',type=int,default=100000)
    p.add_argument('--checkpoint-every',type=int,default=1000);p.add_argument('--batch-size',type=int,default=128)
    p.add_argument('--learning-rate',type=float,default=3e-4);p.add_argument('--seed',type=int,default=20261651)
    p.add_argument('--device',choices=('auto','cpu','cuda'),default='auto');p.add_argument('--limit',type=int)
    mode=p.add_mutually_exclusive_group();mode.add_argument('--evaluate-test',action='store_true');mode.add_argument('--evaluate-benchmark',action='store_true')
    args=p.parse_args();assert args.steps>0 and args.checkpoint_every>0 and args.batch_size>0
    args.out.mkdir(parents=True,exist_ok=False)
    if args.evaluate_test or args.evaluate_benchmark:evaluate(args)
    else:train(args)
if __name__=='__main__':main()
